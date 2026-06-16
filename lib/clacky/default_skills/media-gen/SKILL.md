---
name: media-gen
description: 'Generate images, videos, and audio (text-to-speech) inside the current task. Use this skill whenever the user asks to create, generate, or produce a picture / image / illustration / cover / poster / icon / artwork, OR a video / clip / animation, OR speech / voiceover / narration / TTS / audio — including phrases like 生成图片, 画一张, 做封面, 来张配图, generate image, make a picture, draw, create artwork, design a cover, 生成视频, 做个视频, 来段视频, generate video, make a video, create a clip, text-to-video, 朗读, 配音, 旁白, 文字转语音, 生成语音, generate speech, text to speech, voiceover, narrate. Also use when building documents (slides, PPT, posters, marketing pages, README hero shots) where an image is needed inline. Routes calls through the local Clacky HTTP server, which uses the user-configured `type=image` / `type=video` / `type=audio` model — you do NOT need to know which provider; the server handles it.'
disable-model-invocation: false
user-invocable: true
always-show: true
---

# media-gen

Generate images on demand by calling the local Clacky HTTP server, which dispatches to whichever image-generation model the user configured (`type=image` in their model settings).

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

> 还没有配置生图模型。请打开 Clacky 设置页 → 添加模型 → 类型选 `image`（推荐 `or-gemini-3-pro-image` 或 `or-gpt-image-1`）。配好后再让我生图。

Do NOT try to fall back to `terminal` + a hand-written `curl https://api.openai.com/...` — that bypasses the user's configured backend and won't be billed correctly.

## Step 2 — Generate the image

### ⚠️  Important: generation speed & concurrency

- **Image generation can be slow — up to 2 minutes per image depending on the model.** Before calling the API, warn the user that it may take a minute or two. The curl request blocks until the image is ready; do NOT run it in the background.
- **One at a time only.** Never generate multiple images concurrently (e.g. by running several `curl` commands simultaneously or in a script loop). Each call consumes significant server-side resources, and parallel requests will almost certainly cause timeouts. If the user wants several images, generate them **sequentially**, one after another.

```bash
curl -s -X POST http://${CLACKY_SERVER_HOST}:${CLACKY_SERVER_PORT}/api/media/image \
  -H "Content-Type: application/json" \
  -d '{
    "prompt": "A clean, modern hero illustration for a tech startup landing page. Soft gradient background, abstract geometric shapes in blue and purple, minimal style, 4K quality.",
    "aspect_ratio": "landscape"
  }'
```

### Request fields

| Field          | Required | Values                              | Notes |
|----------------|----------|-------------------------------------|-------|
| `prompt`       | yes      | string                              | Be detailed and concrete. See prompt tips below. |
| `aspect_ratio` | no       | `landscape` / `square` / `portrait` | Defaults to `landscape`. |
| `output_dir`   | no       | absolute path                       | Defaults to the current working directory. The image is saved under `<output_dir>/assets/generated/`. |

### Response shape (success)

```json
{
  "success": true,
  "image": "/abs/path/to/working_dir/assets/generated/img_20260525_011820_a1b2c3d4.png",
  "model": "or-gemini-3-pro-image",
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

- The user asks to **edit** an existing image (this skill is text-to-image only today)
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

### ⚠️ Video is slow and expensive

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
    "duration_seconds": 8
  }'
```

| Field              | Required | Values                          | Notes |
|--------------------|----------|---------------------------------|-------|
| `prompt`           | yes      | string                          | Same prompt-craft tips as images apply. |
| `aspect_ratio`     | no       | `landscape` / `portrait`        | Defaults to `landscape` (16:9). |
| `duration_seconds` | no       | 4–8                             | Defaults to 8. |
| `image`            | no       | `{ "b64_json": "...", "mime_type": "image/png" }` | Optional first frame for image-to-video. |
| `output_dir`       | no       | absolute path                   | MP4 saved under `<output_dir>/assets/generated/`. |

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
    "voice": "Kore"
  }'
```

| Field        | Required | Values                          | Notes |
|--------------|----------|---------------------------------|-------|
| `input`      | yes      | string                          | The text to speak. Plain prose works best; you can prefix with style cues like "Say cheerfully:" or "In a calm tone:". |
| `voice`      | no       | string voice name               | Defaults to `Kore`. Common Gemini voices: `Kore`, `Puck`, `Charon`, `Fenrir`, `Aoede`. |
| `output_dir` | no       | absolute path                   | WAV saved under `<output_dir>/assets/generated/`. |

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

