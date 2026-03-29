---
name: oss-upload
description: Upload local files to Tencent COS (oss.1024code.com CDN) using coscli. Use when user wants to upload a file to CDN/OSS, or deploy static assets.
---

# OSS Upload Skill

Upload files to Tencent COS bucket `clackyai-1258723534`, served via `https://oss.1024code.com`.

## Tool
`coscli` — config at `~/.cos.yaml`

## Bucket Info
- Bucket: `clackyai-1258723534`
- Region: `ap-guangzhou`
- Endpoint: `cos.ap-guangzhou.myqcloud.com`
- Public CDN: `https://oss.1024code.com/<path>`

## Upload Command

```bash
coscli cp <local-file> cos://clackyai-1258723534/<remote-path>
```

### Examples

```bash
# Upload a single file to bucket root
coscli cp /tmp/wsl.2.6.3.0.arm64.msi cos://clackyai-1258723534/wsl.2.6.3.0.arm64.msi

# Upload to a subdirectory
coscli cp /tmp/install.ps1 cos://clackyai-1258723534/clacky-ai/openclacky/main/scripts/install.ps1

# Upload entire directory recursively
coscli cp /tmp/dist/ cos://clackyai-1258723534/dist/ -r
```

## Public URL
After upload, the file is accessible at:
```
https://oss.1024code.com/<remote-path>
```

## Steps
1. Confirm local file exists
2. Run `coscli cp <local> cos://clackyai-1258723534/<path>`
3. Return the public URL: `https://oss.1024code.com/<path>`
