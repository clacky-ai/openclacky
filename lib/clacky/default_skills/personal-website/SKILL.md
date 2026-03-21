---
name: personal-website
description: |
  Generate a beautiful personal homepage (linktree-style) and publish it online for the user.
  Reads user info from ~/.clacky/agents/USER.md and AI info from ~/.clacky/agents/SOUL.md.
  Returns a public URL the user can share.
  Trigger on: "profile card", "homepage", "personal page", "generate my card", "make my card",
  "publish my card", "生成名片", "做名片", "我的名片", "个人主页", "发布主页",
  "delete my card", "删除名片", "删除主页".
allowed-tools:
  - Bash
  - Read
  - Write
---

# Profile Homepage Skill

Generate a beautiful personal homepage and publish it at a public URL.

---

## Step 1 — Read user info

Read `~/.clacky/agents/USER.md` and `~/.clacky/agents/SOUL.md`.

Extract everything you can find:
- `name` — display name (fallback: "Friend")
- `occupation` — job title or role (fallback: "")
- `bio` — short personal description (fallback: "")
- `links` — **all** social/contact links found, preserve their labels. Common ones to look for:
  GitHub, Twitter/X, LinkedIn, Website, Blog, Email, Instagram, YouTube, Telegram, WeChat, etc.
  Each link: `{ label, url, type }` where type helps pick an icon emoji.
- `ai_name` — AI assistant name from SOUL.md (fallback: "Clacky")
- `personality` — professional / friendly / creative / concise (from SOUL.md, fallback: "friendly")

---

## Step 2 — Handle delete request

If the user asked to **delete** their homepage:
1. Find the skill's own directory (same folder as this SKILL.md). Call it `SKILL_DIR`.
2. Run:
   ```bash
   ruby SKILL_DIR/publish.rb delete
   ```
   The script reads the slug automatically from `~/clacky_workspace/personal_website/token.json`.
3. Tell the user their homepage has been removed. Stop here.

---

## Step 3 — Design & generate the HTML

Write a **complete, self-contained** HTML file to `/tmp/profile-card.html`.

### You have full creative freedom on:
- Layout, typography, spacing, color palette
- Background (solid / gradient / subtle pattern / animated)
- Link button style (pill / card / underline / ghost / anything)
- Avatar treatment (large initial letter with color, emoji, geometric shape — no real image needed)
- Animations (subtle hover effects, entrance fade, etc.)
- Overall vibe — make it feel like a real personal brand page, not a template

### Hard constraints (must follow):
- **Single HTML file, zero external resources** — no CDN, no Google Fonts URLs, no `<img src="http...">`.
  Use system fonts: `'Helvetica Neue', Arial, 'PingFang SC', 'Hiragino Sans GB', sans-serif`
- **Mobile-first, responsive** — `<meta name="viewport">` required, works on phone screens
- **Valid HTML5**
- **All links open in `_blank`** with `rel="noopener"`
- **Badge** somewhere subtle: `made by {ai_name} personal assistant` — small, not intrusive
- Page `<title>`: `{name}'s Homepage` or similar

### Link icons (use emoji prefix in button text):
| Type     | Emoji |
|----------|-------|
| github   | 🐙 |
| twitter/x | 🐦 |
| linkedin | 💼 |
| website/blog | 🌐 |
| email    | 📧 |
| instagram | 📸 |
| youtube  | ▶️ |
| telegram | ✈️ |
| default  | 🔗 |

---

## Step 4 — Publish

Find the skill directory (same folder as this SKILL.md). Call it `SKILL_DIR`.

Run:
```bash
ruby SKILL_DIR/publish.rb publish \
  --name "NAME" \
  --html-file /tmp/profile-card.html
```

- First publish → creates new page, saves token to `~/clacky_workspace/personal_website/token.json`
- Subsequent runs → updates existing page at the same URL

Capture stdout. Extract the URL from the output line starting with `✅`.

---

## Step 5 — Done

Tell the user their homepage is live. Share the URL. Be warm and natural.

Example (adapt tone to personality):
> Your homepage is live 🌟
> → http://localhost:3000/~ya-fei
>
> It's got all your links in one place. Share it anywhere.
