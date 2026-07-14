---
name: media-gen
description: 'Generate or edit images, videos, or audio (text-to-speech) in the current task. Use whenever the user asks to create/generate/produce or edit/modify a picture / image / illustration / cover / poster / icon / artwork, a video / clip / animation, or speech / voiceover / narration / TTS — e.g. generate image, draw, design a cover, edit this image, change the background, text-to-video, generate speech; 画一张, 配图, 编辑图片, 改图, 换背景, 做个视频, 配音, 文字转语音. Also use when a document (slides, poster, README hero) needs an inline image.'
disable-model-invocation: false
user-invocable: true
always-show: true
---

# media-gen

Generate **and edit** images on demand by calling the local Clacky HTTP server, which dispatches to whichever image-generation model the user configured (`type=image` in their model settings). Editing (image-in → image-out) works with any image model that accepts image input — most current ones do.

## Endpoint

```
POST http://${CLACKY_SERVER_HOST}:${CLACKY_SERVER_PORT}/api/media/image
GET  http://${CLACKY_SERVER_HOST}:${CLACKY_SERVER_PORT}/api/media/types
```

## Step 1 — Verify a backend is configured

Before generating anything, confirm the user has a `type=image` model set up:

```bash
curl -s http://${CLACKY_SERVER_HOST}:${CLACKY_SERVER_PORT}/api/media/types
```

If the response shows `image.configured = false`, stop and tell the user:

> 还没有配置生图模型。请打开设置页 → 添加模型 → 类型选 `image`（走 openclacky 官方网关时推荐 `or-gemini-3-pro-image` 或 `or-gpt-image-2`）。配好后再让我生图。

Do NOT try to fall back to `terminal` + a hand-written `curl https://api.openai.com/...` — that bypasses the user's configured backend and won't be billed correctly.

**You do NOT configure models — the user does, in the settings page.** Never
edit the user's `config.yml` to add or change a model, and never invent a model
name from memory (e.g. `or-gpt-5.4-image-2` does not exist). The real, current
model is whatever `/api/media/types` reports under `image.model`. If you think a
different model is needed, tell the user which one to set in the settings page —
don't touch the config file yourself.

## Step 2 — Generate the image

### The model does NOT honor exact pixel sizes

There is no `size` / `width` / `height` field — the only shape control is
`aspect_ratio` (`landscape` / `square` / `portrait`), and even that is just a
rough hint (ask for `576x96` and you may get `1408x768`). When the user needs an
**exact pixel size, a grid, an icon at NxN, or a spritesheet**, generate first at
whatever size the model gives, then resize / crop / tile to the exact pixels with
ImageMagick (`magick`). Verify with `magick identify` before reporting done.

### Important: generation speed & concurrency

- **Image generation can be slow — up to 2 minutes per image depending on the model.** Before calling the API, warn the user that it may take a minute or two. The curl request blocks until the image is ready; do NOT run it in the background.
- **One at a time only.** Never generate multiple images concurrently (e.g. by running several `curl` commands simultaneously or in a script loop). Each call consumes significant server-side resources, and parallel requests will almost certainly cause timeouts. If the user wants several images, generate them **sequentially**, one after another.

```bash
curl -s -X POST http://${CLACKY_SERVER_HOST}:${CLACKY_SERVER_PORT}/api/media/image \
  -H "Content-Type: application/json" \
  -d '{
    "prompt": "A clean, modern hero illustration for a tech startup landing page. Soft gradient background, abstract geometric shapes in blue and purple, minimal style, 4K quality.",
    "aspect_ratio": "landscape",
    "output_dir": "'"$(pwd)"'",
    "session_id": "<%= session_id %>"
  }'
```

- The terminal blocks multi-line commands — write the request into a `.sh` file and run it, don't paste a multi-line `curl`.
- If a call fails with `400 / INVALID_ARGUMENT`, drop the `aspect_ratio` field and retry once before reporting the error.
- If a call fails with `unknown image model` (400), the configured model name isn't recognized by its backend — tell the user to fix the model name in the settings page; do NOT guess another name and retry.

### Request fields

| Field          | Required | Values                              | Notes |
|----------------|----------|-------------------------------------|-------|
| `prompt`       | yes      | string                              | Be detailed and concrete. See prompt tips below. |
| `aspect_ratio` | no       | `landscape` / `square` / `portrait` | Defaults to `landscape`. |
| `output_dir`   | yes      | absolute path                       | Always pass `$(pwd)` so files land in the current session workspace. The image is saved under `<output_dir>/assets/generated/`. |
| `session_id`   | yes      | string                              | Current Clacky session ID. Always pass the rendered value shown in the request example. |
| `image`        | no       | file path / base64 / data URL       | A single input image to **edit**. Triggers image-edit mode (see below). |
| `images`       | no       | array of the above                  | Multiple input images for a multi-image edit. Takes precedence over `image`. |

### Editing an existing image

To edit instead of generate from scratch, pass the existing image as `image`
(a local file path is easiest — the skill reads and encodes it for you) plus a
`prompt` describing the change. The configured image model receives the
image alongside the prompt and returns an edited result.

```bash
curl -s -X POST http://${CLACKY_SERVER_HOST}:${CLACKY_SERVER_PORT}/api/media/image \
  -H "Content-Type: application/json" \
  -d '{
    "prompt": "change the background to a starry night sky, keep the cat unchanged",
    "image": "/abs/path/to/input.png",
    "session_id": "<%= session_id %>"
  }'
```

- The result is a **new** edited image saved under `assets/generated/` — the
  original file is never modified in place.
- For combining several inputs (e.g. "put the product from image 1 onto the
  background from image 2"), pass them as `images: ["/path/a.png", "/path/b.png"]`
  and describe the composition in the prompt.
- Same speed/concurrency rules apply: editing is as slow as generation, one at a time.

### Response shape (success)

```json
{
  "success": true,
  "image": "/abs/path/to/working_dir/assets/generated/img_20260525_011820_a1b2c3d4.png",
  "model": "<the configured image model>",
  "provider": "openclacky",
  "prompt": "A clean, modern hero illustration ...",
  "aspect_ratio": "landscape",
  "size": "1536x1024",
  "usage": {
    "prompt_tokens": 50,
    "completion_tokens": 4500,
    "cache_read_tokens": 0,
    "cache_write_tokens": 0,
    "total_tokens": 4550
  }
}
```

The `image` field is an absolute path on disk. To embed it in markdown, slides, or HTML, convert it to a path relative to the document you're writing.

`usage` may be absent when the configured backend doesn't return token counts. Treat it as optional.

### Response shape (failure)

```json
{
  "success": false,
  "image": null,
  "error": "Upstream 401: Invalid API key",
  "error_type": "api_error",
  "model": "...",
  "provider": "..."
}
```

Common `error_type` values: `not_configured`, `auth_required`, `network_error`, `api_error`, `empty_response`. Tell the user the error plainly; if it's `auth_required` or `api_error 401/403`, point them at settings to fix the api_key.

## Step 3 — Show the image

`Read` does NOT show the image to the user — it only feeds it into your own context. To make the user actually see it, write a markdown tag in your reply:

```markdown
![](file:///abs/path/from/response.png)
```

Take the `image` field from the response and prefix `file://` (three slashes, since the path is absolute).

If you're also embedding it in a document (README, PPT, etc.), use a relative path: `![](./assets/generated/xxx.png)`.

## Prompt writing tips

A good image prompt has 4 layers, in this order:

1. **Subject** — what is in the image, concretely. ("a golden retriever puppy", "a stylized icon of a rocket")
2. **Style / medium** — photo / illustration / 3D render / watercolor / flat vector / line art
3. **Composition / lighting** — close-up / wide shot / overhead / soft natural light / dramatic backlight
4. **Mood / palette** — minimal / playful / corporate / pastel / high-contrast monochrome

For PPT / slide decks specifically:
- Hero / cover slides: `aspect_ratio: landscape`, prompt should emphasise "clean", "minimal", "negative space" so text overlays well
- Section dividers: `aspect_ratio: landscape`, abstract or pattern-style works better than literal subjects
- Inline figures: `aspect_ratio: square` or `portrait`, more literal subject is fine

When the user gives a vague request like "给我配张图", ask one clarifying question (subject? style?) before calling the API — costs real money per image.

## When NOT to use this skill

- The user wants a **diagram / chart** with specific data — use a charting library (matplotlib, mermaid, etc.) instead; image gen is for illustrations, not data viz
- The user asks for **screenshots** of real software — use the browser tool

## Generating video (Veo)

The same `/api/media/` namespace serves video generation. The user must
configure a `type=video` model in settings (recommended: `or-veo-3-1`).

### Endpoint

```
POST http://${CLACKY_SERVER_HOST}:${CLACKY_SERVER_PORT}/api/media/video
```

Check `GET /api/media/types` first — if `video.configured = false`, tell the
user to add a `type=video` model in settings before generating.

### Video is slow and expensive

- **A single clip can take 1–3 minutes (sometimes longer).** Warn the user
  before calling, and run the curl in the foreground — it blocks until the
  MP4 is ready. Do NOT background it.
- **One at a time.** Never run multiple video generations concurrently.
- Each clip costs real money (billed per output-second). Confirm the prompt
  with the user before generating.

### Request

```bash
curl -s -X POST http://${CLACKY_SERVER_HOST}:${CLACKY_SERVER_PORT}/api/media/video \
  -H "Content-Type: application/json" \
  -d '{
    "prompt": "A cinematic drone shot flying over a misty mountain range at sunrise, golden light, 4K.",
    "aspect_ratio": "landscape",
    "duration_seconds": 8,
    "output_dir": "'"$(pwd)"'",
    "session_id": "<%= session_id %>"
  }'
```

| Field              | Required | Values                          | Notes |
|--------------------|----------|---------------------------------|-------|
| `prompt`           | yes      | string                          | Same prompt-craft tips as images apply. |
| `aspect_ratio`     | no       | `landscape` / `portrait`        | Defaults to `landscape` (16:9). |
| `duration_seconds` | no       | 4–8                             | Defaults to 8. |
| `image`            | no       | `{ "b64_json": "...", "mime_type": "image/png" }` | Optional first frame for image-to-video. |
| `output_dir`       | yes      | absolute path                   | Always pass `$(pwd)` so files land in the current session workspace. MP4 saved under `<output_dir>/assets/generated/`. |
| `session_id`       | yes      | string                          | Current Clacky session ID. Always pass the rendered value shown in the request example. |

### Response (success)

```json
{
  "success": true,
  "video": "/abs/path/to/working_dir/assets/generated/vid_20260615_011820_a1b2c3d4.mp4",
  "model": "or-veo-3-1",
  "provider": "openclacky",
  "prompt": "A cinematic drone shot ...",
  "aspect_ratio": "landscape",
  "duration_seconds": 8,
  "cost_usd": 2.688
}
```

The `video` field is an absolute path on disk. Show it to the user with a
markdown link or an HTML5 `<video>` tag pointing at the `file://` path; embed
it in documents with a relative path under `./assets/generated/`.

### Response (failure)

Same shape and `error_type` values as image generation, but with `"video": null`.
`not_configured` means no `type=video` model is set up.

### Continuous / long video (last-frame chaining)

A single Veo call maxes out at 8 seconds, and separate calls are visually
**unrelated** (the character, lighting and framing jump between clips). To make
several clips flow as one continuous shot, chain them: take the **last frame**
of clip N and feed it as the `image` (first frame) of clip N+1. Veo's
image-to-video then continues from exactly where the previous clip ended, so
the seam is smooth.

Use the helper script (it only does the ffmpeg mechanics — you drive the
generation with the same `/api/media/video` curl as above). The script's
absolute path is given in the **Supporting Files** block; assign it once:

```bash
SEQ="SKILL_DIR/scripts/video_seq.sh"   # SKILL_DIR is provided in Supporting Files
# subcommands: lastframe | tob64 | payload | concat | probe
```

Workflow for an N-segment continuous video:

1. **Plan the shots.** Split the story into 4–8s beats. Write one prompt per
   beat; each prompt should describe the *continuation*, e.g. "The same girl
   keeps walking forward, the camera pushes in…". Keep subject, style and
   lighting wording consistent across prompts.
2. **Segment 1** — normal text-to-video call. Save the returned mp4 path.
3. **Extract its last frame** (as JPEG — keep the `.jpg` extension):
   ```bash
   "$SEQ" lastframe seg1.mp4 /tmp/seg1_last.jpg
   ```
4. **Segment 2** — build the request body with `payload`, then post it with
   `curl --data @file`. **Do NOT inline the base64 into `-d "{…}"`** — a frame's
   base64 is ~150KB+ and overflows the shell's argument limit ("Argument list
   too long"). The `payload` subcommand reads the frame, base64-encodes it, and
   writes a ready-to-send JSON file:
   ```bash
   "$SEQ" payload /tmp/seg2.json /tmp/seg1_last.jpg 8 landscape "$OUT_DIR" \
     "Continuing the same scene, the camera keeps pushing forward…" "<%= session_id %>"
   curl -s -X POST .../api/media/video -H "Content-Type: application/json" \
     --data @/tmp/seg2.json
   ```
   (`payload <out.json> <frame> <duration_seconds> <aspect_ratio> <output_dir> <prompt> [session_id]`)
5. **Repeat** steps 3–4 for each subsequent segment, always chaining off the
   *previous* segment's last frame.
6. **Stitch** all clips in order into one file:
   ```bash
   "$SEQ" concat final.mp4 seg1.mp4 seg2.mp4 seg3.mp4
   ```

Rules & caveats:

- **Strictly sequential.** Generate one segment, wait for it, extract its
  frame, then start the next. Never run two video generations at once.
- **Keep prompts consistent.** The image carries visual continuity, but the
  prompt must not contradict it (don't switch the subject or scene mid-chain
  unless you intend a cut).
- **Aspect ratio must match** across all segments, or `concat` falls back to a
  slower re-encode (and may letterbox). Use the same `aspect_ratio` everywhere.
- **Cost adds up linearly** — N segments ≈ N × single-clip price. Confirm the
  number of segments and total length with the user before starting.
- For >30s or a true single-take >8s with no seam at all, this client-side
  chaining is the practical option today; Veo's native server-side `extend`
  (148s) is not wired into this endpoint yet.

### Seedance (Volcengine Ark) — multimodal video

When the configured `type=video` model is a ByteDance **Doubao Seedance**
model on Volcengine Ark (its Base URL is under `*.volces.com`, e.g.
`https://ark.cn-beijing.volces.com/api/v3`), the **same**
`POST /api/media/video` endpoint drives it. No separate endpoint — the server
routes by Base URL automatically. Seedance adds richer inputs on top of the
common fields; all are optional and only apply to Seedance:

> **Cost gate — ask before EVERY generation.** Resolution is the main driver
> of Seedance's price (4k costs far more than 720p). So **once you've confirmed
> via `GET /api/media/types` that the `type=video` Base URL is under
> `*.volces.com`, you MUST ask the user which resolution they want before EACH
> AND EVERY billable call** — this covers not just a brand-new clip but also
> editing, multimodal reference, and extending/continuing an existing video
> (they all cost the same as a fresh render). Offer `480p` / `720p` / `1080p` /
> `4k` and state the default is `720p`. Only after they answer (or explicitly
> say "use the default") do you proceed, passing their choice as `resolution`.
> **Ask again every single time — a resolution the user picked for one clip is
> NEVER carried over to the next generation. Do not assume, do not reuse a
> prior answer, do not batch. One generation = one fresh resolution question.**
> **When editing or continuing/extending an existing video, default to that
> source video's resolution — never silently upgrade it (e.g. don't turn a
> 720p source into a 4k render).** If the user gave no answer and you didn't
> ask, the server pins `720p`. **These Seedance-only fields (`resolution`,
> `generate_audio`, `watermark`, `seed`, `first_frame`, `last_frame`,
> `reference_*`) have NO effect on Veo or Qwen/DashScope backends — never send
> them unless the Base URL is `*.volces.com`.**

| Field              | Values                                   | Notes |
|--------------------|------------------------------------------|-------|
| `aspect_ratio`     | `landscape`/`portrait`/`square`, or a raw Ark ratio like `16:9`, `9:16`, `4:3`, `3:4`, `21:9`, `adaptive` | Raw ratios pass through unchanged. |
| `duration_seconds` | integer, or `-1`                         | `-1` lets the model pick the length (Seedance 2.0 / 1.5 Pro). |
| `resolution`       | `480p` / `720p` / `1080p` / `4k`         | **Defaults to `720p` when omitted** (cost control). Ask the user before every generation — never reuse a prior answer. See the cost gate above. Model-dependent; unsupported values are rejected upstream. |
| `generate_audio`   | `true` / `false`                         | Seedance 2.0 / 1.5 Pro can synthesize a synced audio track. |
| `watermark`        | `true` / `false`                         | |
| `seed`             | integer                                  | Reproducibility. |
| `first_frame`      | media ref (see below)                    | First frame → image-to-video. |
| `last_frame`       | media ref                                | Together with `first_frame` → first+last-frame video. |
| `reference_images` | array of media refs (0–9)                | Reference images. |
| `reference_videos` | array of media refs (0–3)                | Reference videos. |
| `reference_audios` | array of media refs (0–3)                | Reference audio (background music / voice). |

**Which fields for which task** — Seedance covers six capabilities; pick the
fields by intent, and never mix the two families below:

| Task | What you want | Fields to send |
|------|---------------|----------------|
| Text-to-video | a clip from a prompt only | `prompt` (no media) |
| Image-to-video (first frame) | animate a still image forward | `first_frame` |
| Image-to-video (first + last frame) | interpolate between two stills | `first_frame` + `last_frame` |
| Multimodal generation | new clip guided by reference images/videos/audio | `reference_images` / `reference_videos` / `reference_audios` |
| **Edit an existing video** | replace/add/remove/repaint something *inside* a given video | `reference_videos: [<the video to edit>]` (+ optional `reference_images` / `reference_audios`) + a prompt describing the edit |
| **Extend / continue a video** | prepend/append or stitch clips into one | `reference_videos: [<clip1>, <clip2>, ...]` (up to 3) + a prompt describing the join |

> **🚫 Hard rule — the two families are mutually exclusive.**
> `first_frame`/`last_frame` **cannot** be combined with any `reference_*`
> field; Ark rejects the request. If the user wants to **edit or extend an
> existing video, that is a `reference_videos` task — do NOT fall back to
> extracting a frame and using `first_frame`** (that produces a brand-new clip
> and silently loses the "edit the original" intent). The server also enforces
> this and returns a clear `invalid_argument` error if you mix them.

A **media ref** may be:
- a public `http(s)://` URL, or a `data:` URL, or
- a local file path (the server reads and base64-encodes it), or
- a `{ "b64_json": "...", "mime_type": "image/png" }` hash.

Note: audio cannot be sent alone — pair it with at least one image or video.
Prefer passing large videos/audios as public URLs; base64-encoding a big local
file can exceed upstream size limits.

Example — **first + last frame** (image-to-video, no `reference_*`):

```bash
curl -s -X POST http://${CLACKY_SERVER_HOST}:${CLACKY_SERVER_PORT}/api/media/video \
  -H "Content-Type: application/json" \
  -d '{
    "prompt": "First-person POV, a hand raises a cup of fruit tea toward the camera, bright and refreshing lighting",
    "aspect_ratio": "9:16",
    "duration_seconds": 8,
    "resolution": "720p",
    "first_frame": "'"$(pwd)"'/assets/frame_first.jpg",
    "last_frame": "'"$(pwd)"'/assets/frame_last.jpg",
    "output_dir": "'"$(pwd)"'",
    "session_id": "<%= session_id %>"
  }'
```

Example — **edit an existing video** (replace/add/remove something inside it;
uses `reference_videos`, NOT `first_frame`):

```bash
curl -s -X POST http://${CLACKY_SERVER_HOST}:${CLACKY_SERVER_PORT}/api/media/video \
  -H "Content-Type: application/json" \
  -d '{
    "prompt": "Add a small wooden fishing boat with a warm lantern drifting slowly across the lake in the foreground, keep everything else unchanged",
    "resolution": "720p",
    "reference_videos": ["'"$(pwd)"'/assets/original.mp4"],
    "output_dir": "'"$(pwd)"'",
    "session_id": "<%= session_id %>"
  }'
```

**Seedance is asynchronous — POST only submits, it does NOT return the video.**
Unlike Veo (which blocks and returns the mp4 in one call), the Seedance POST
returns immediately with a task id:

```json
{ "success": true, "status": "submitted", "task_id": "cgt-2024...-xxxx", "provider": "volcengine" }
```

`status: "submitted"` means the render is now running on Volcengine's servers
and **is already being billed** — it does NOT mean it is done. You MUST now
poll for completion: sleep ~15 seconds, then query the status endpoint, and
repeat until it is `succeeded` (or `failed`):

```bash
curl -s "http://${CLACKY_SERVER_HOST}:${CLACKY_SERVER_PORT}/api/media/video/status?task_id=cgt-2024...-xxxx&output_dir=$(pwd)&session_id=<%= session_id %>"
```

Status responses:

```json
{ "success": true,  "status": "running" }                         // keep polling
{ "success": true,  "status": "succeeded", "video": "/abs/path.mp4" }  // done — this is the file
{ "success": false, "status": "failed", "error": "..." }          // give up, report to user
```

Only once you receive `status: "succeeded"` and the absolute `video` path may
you present the result to the user. Do NOT end your turn while the task is
still `submitted`/`running` — the user is waiting for the finished video.

A minimal poll loop:

```bash
TASK_ID=$(curl -s -X POST http://${CLACKY_SERVER_HOST}:${CLACKY_SERVER_PORT}/api/media/video \
  -H "Content-Type: application/json" \
  -d '{"prompt":"...","resolution":"720p","output_dir":"'"$(pwd)"'","session_id":"<%= session_id %>"}' \
  | sed -n 's/.*"task_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

while true; do
  sleep 15
  RESP=$(curl -s "http://${CLACKY_SERVER_HOST}:${CLACKY_SERVER_PORT}/api/media/video/status?task_id=${TASK_ID}&output_dir=$(pwd)&session_id=<%= session_id %>")
  STATUS=$(echo "$RESP" | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  echo "poll: $STATUS"
  [ "$STATUS" = "succeeded" ] && echo "$RESP" && break
  [ "$STATUS" = "failed" ] && echo "$RESP" && break
done
```

**Hard rules — a broken version of this once doubled a user's bill:**

- ❌ **Never POST the same generation twice.** Once you have a `task_id`, the
  only valid next action is polling `/api/media/video/status`. A slow render
  is not a failed one.
- ⚠️ **A timeout or error is NOT proof the task failed.** The task keeps
  running and billing on Volcengine's side. Always query the status endpoint
  to find out the real state before doing anything else — never resubmit.
- ❌ **Never kill the poll to "cancel" the job.** Killing your curl/session
  does not stop the Volcengine task; it keeps running and billing. A running
  task also cannot be deleted upstream.
- ❌ **Never bypass `/api/media/*` to call Volcengine's native API directly.**
  All submission and status checks must go through this server (it meters
  cost). There is no reason to touch the raw Ark API.
- ⏱️ If polling exceeds ~15 minutes and status is still `running`, stop
  polling and tell the user the task is still rendering in the background,
  give them the `task_id`, and let them check again later — do NOT resubmit.

## Generating speech (Gemini TTS)

The same `/api/media/` namespace serves text-to-speech. The user must
configure a `type=audio` model in settings (recommended:
`or-tts-gemini-2-5-flash`, the cheap+fast default).

### Endpoint

```
POST http://${CLACKY_SERVER_HOST}:${CLACKY_SERVER_PORT}/api/media/audio/speech
```

Check `GET /api/media/types` first — if `audio.configured = false`, tell the
user to add a `type=audio` model in settings before generating.

### Request

```bash
curl -s -X POST http://${CLACKY_SERVER_HOST}:${CLACKY_SERVER_PORT}/api/media/audio/speech \
  -H "Content-Type: application/json" \
  -d '{
    "input": "Hello and welcome to openclacky. Today we will explore...",
    "voice": "Kore",
    "output_dir": "'"$(pwd)"'",
    "session_id": "<%= session_id %>"
  }'
```

| Field        | Required | Values                          | Notes |
|--------------|----------|---------------------------------|-------|
| `input`      | yes      | string                          | The text to speak. Plain prose works best; you can prefix with style cues like "Say cheerfully:" or "In a calm tone:". |
| `voice`      | no       | string voice name               | Defaults to `Kore`. Common Gemini voices: `Kore`, `Puck`, `Charon`, `Fenrir`, `Aoede`. |
| `output_dir` | yes      | absolute path                   | Always pass `$(pwd)` so files land in the current session workspace. WAV saved under `<output_dir>/assets/generated/`. |
| `session_id` | yes      | string                          | Current Clacky session ID. Always pass the rendered value shown in the request example. |

Generation typically takes 2–10 seconds depending on length. The request
blocks until the WAV is ready.

### Response (success)

```json
{
  "success": true,
  "audio": "/abs/path/to/working_dir/assets/generated/tts_20260615_233522_4ff02705.wav",
  "model": "or-tts-gemini-2-5-flash",
  "provider": "openclacky",
  "input": "Hello and welcome to openclacky...",
  "voice": "Kore",
  "mime_type": "audio/wav",
  "usage": { "prompt_tokens": 13, "completion_tokens": 122, "total_tokens": 135 },
  "cost_usd": 0.000259
}
```

The `audio` field is an absolute path on disk. Output is mono 16-bit PCM at
24 kHz wrapped in a standard WAV container — playable by any browser, OS
player, or `<audio>` tag without conversion.

To let the user hear it, write a markdown link in your reply:

```markdown
[🔊 听一下](file:///abs/path/from/response.wav)
```

For embedding in HTML documents, use:

```html
<audio controls src="./assets/generated/xxx.wav"></audio>
```

### Response (failure)

Same shape and `error_type` values as image generation, but with `"audio": null`.
`not_configured` means no `type=audio` model is set up.

### Cost & length tips

- Gemini TTS bills by tokens (input text + generated audio). A typical
  one-paragraph narration costs well under $0.001.
- For long-form audio (>1 minute), split the script into paragraphs and
  generate each separately, then concatenate locally — avoids upstream
  truncation and gives you finer control over pacing.
- Voice consistency: Gemini TTS does not currently support voice cloning;
  use the same `voice` name across calls in one project to keep the
  narrator consistent.
