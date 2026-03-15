---
name: activate-license
description: Guide the user through activating their brand license key interactively.
disable-model-invocation: true
user-invocable: true
---

# Skill: activate-license

## Purpose
Guide the user to enter and submit their brand license key to activate the software.
All structured input is gathered through `request_user_feedback` cards — no free-form interrogation.

## Steps

### 0. Detect language

The skill is invoked with a `lang:` argument, e.g. `/activate-license lang:zh` or `/activate-license lang:en`.
Check the invocation message:
- If `lang:zh` is present → conduct entirely in **Chinese**.
- Otherwise → use **English** throughout.

Also check for a `name:` argument (e.g. `name:MyBrand`). Store as `brand_name` (default empty).

### 1. Greet the user

Send a short, warm welcome message. Use the language determined in Step 0.
Do NOT ask for the key yet.

Example (Chinese):
> 👋 欢迎使用{{brand_name}}！
> 只需输入您的授权码，即可解锁全部功能。授权码格式为：`XXXXXXXX-XXXXXXXX-XXXXXXXX-XXXXXXXX-XXXXXXXX`

Example (English):
> 👋 Welcome to {{brand_name}}!
> Enter your license key to unlock all features. The format is: `XXXXXXXX-XXXXXXXX-XXXXXXXX-XXXXXXXX-XXXXXXXX`

### 2. Ask for the license key (card)

Call `request_user_feedback` to collect the license key.

If `lang == "zh"`, use:
```json
{
  "question": "请输入您的授权码：",
  "options": []
}
```

Otherwise (English):
```json
{
  "question": "Please enter your license key:",
  "options": []
}
```

Store the user's reply as `license_key` (trimmed).

### 3. Submit the license key via API

Call the activation API using the shell tool:

```bash
curl -s -X POST http://localhost:PORT/api/brand/activate \
  -H "Content-Type: application/json" \
  -d '{"license_key": "LICENSE_KEY_HERE"}'
```

To find the running port, check the environment or use `http://localhost:7002` as the default.
Try ports 7002, 7003, 7004 if the first fails. Parse the JSON response:
- `ok: true` → activation succeeded, `brand_name` may be in response
- `ok: false` → activation failed, `error` field contains the reason

### 4a. On success

If `lang == "zh"`, reply:
> 🎉 授权激活成功！欢迎使用 {{brand_name}}。
> 关闭此会话，即可开始使用全部功能。

Otherwise:
> 🎉 License activated successfully! Welcome to {{brand_name}}.
> Close this session to start using all features.

### 4b. On failure

If the key format is invalid (doesn't match `XXXXXXXX-XXXXXXXX-XXXXXXXX-XXXXXXXX-XXXXXXXX`):

If `lang == "zh"`, reply and go back to Step 2:
> ❌ 授权码格式不正确。正确格式为：`XXXXXXXX-XXXXXXXX-XXXXXXXX-XXXXXXXX-XXXXXXXX`
> 请重新输入。

If the API returns an error:

If `lang == "zh"`, reply and go back to Step 2:
> ❌ 激活失败：{{error}}
> 请检查授权码后重试，或联系您的品牌服务商。

Otherwise (English):
> ❌ Activation failed: {{error}}
> Please double-check your license key and try again, or contact your brand provider.

### 5. Retry loop

After a failure, call `request_user_feedback` again to let the user enter a corrected key.
Repeat up to 3 times. If all 3 attempts fail, close gracefully:

If `lang == "zh"`:
> 多次尝试均未成功。请联系您的品牌服务商获取有效授权码。

Otherwise:
> Too many failed attempts. Please contact your brand provider for a valid license key.

## Notes
- Do NOT ask any questions beyond the license key card.
- The key format is exactly: `[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{8}){4}` (5 groups of 8 hex chars).
- Never log or display the license key in cleartext beyond what the user already entered.
- If the port cannot be determined, ask the user with `request_user_feedback`.
