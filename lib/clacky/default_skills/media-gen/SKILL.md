---
name: media-gen
description: 'Generate images (and later videos / audio) inside the current task. Use this skill whenever the user asks to create, generate, or produce a picture / image / illustration / cover / poster / icon / artwork — including phrases like 生成图片, 画一张, 做封面, 来张配图, generate image, make a picture, draw, create artwork, design a cover. Also use when building documents (slides, PPT, posters, marketing pages, README hero shots) where an image is needed inline. Routes calls through the local Clacky HTTP server, which uses the user-configured `type=image` model — you do NOT need to know which provider; the server handles it.'
disable-model-invocation: false
user-invocable: true
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

## Future modalities

The same `/api/media/` namespace will gain `video` and `audio` endpoints. The pattern is identical: the user configures `type=video` / `type=audio` models in settings, this skill (or its successor) calls the matching endpoint.
