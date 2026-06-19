#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Clacky PDF Parser — VLM (Vision Language Model) extractor

Renders each PDF page to PNG via pdftoppm (poppler), then asks the
configured OCR sidecar (e.g. gemini-3-5-flash, gpt-4o-mini) to transcribe
each page through the local Clacky server's internal OCR endpoint.

Why through HTTP and not direct API call?
  The OCR sidecar config (model, base_url, api_key) lives in the agent's
  ~/.clacky/config.yml. We don't re-implement that lookup here — instead
  the local Clacky server exposes /api/internal/ocr-image which already
  has the agent_config in scope. This parser stays a thin client.

Usage:
    python3 pdf_parser_vlm.py <file_path>

Stdout: extracted text (UTF-8), pages separated by `\\n\\n--- Page N ---\\n\\n`
Stderr: progress + error messages
Exit:   0 on success, 1 on failure (server unavailable, no sidecar, etc.)

Environment:
    CLACKY_SERVER_HOST  default 127.0.0.1
    CLACKY_SERVER_PORT  default 7070
"""

import json
import os
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

PAGE_SEPARATOR = "\n\n--- Page {n} ---\n\n"
RENDER_DPI = 150
REQUEST_TIMEOUT = 120  # seconds; VLMs can be slow


def server_url():
    host = os.environ.get("CLACKY_SERVER_HOST", "127.0.0.1")
    port = os.environ.get("CLACKY_SERVER_PORT", "7070")
    return f"http://{host}:{port}/api/internal/ocr-image"


def render_pages(pdf_path, out_dir):
    prefix = os.path.join(out_dir, "page")
    cmd = ["pdftoppm", "-r", str(RENDER_DPI), "-png", pdf_path, prefix]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        sys.stderr.write(f"pdftoppm failed: {proc.stderr.strip()}\n")
        return []
    pages = sorted(
        os.path.join(out_dir, f) for f in os.listdir(out_dir)
        if f.startswith("page-") and f.endswith(".png")
    )
    return pages


def transcribe_page(image_path, page_num):
    with open(image_path, "rb") as f:
        body = f.read()

    boundary = "----clacky-vlm-boundary"
    parts = []
    parts.append(f"--{boundary}\r\n".encode())
    parts.append(
        b'Content-Disposition: form-data; name="image"; filename="page.png"\r\n'
        b"Content-Type: image/png\r\n\r\n"
    )
    parts.append(body)
    parts.append(f"\r\n--{boundary}\r\n".encode())
    parts.append(
        b'Content-Disposition: form-data; name="prompt"\r\n\r\n'
    )
    parts.append(
        f"This is page {page_num} of a scanned PDF. Extract every legible text "
        "verbatim, preserving reading order. Render tables as Markdown tables. "
        "Skip decorative elements. Output plain Markdown only — no commentary."
        .encode()
    )
    parts.append(f"\r\n--{boundary}--\r\n".encode())
    payload = b"".join(parts)

    req = urllib.request.Request(
        server_url(),
        data=payload,
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=REQUEST_TIMEOUT) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except urllib.error.URLError as e:
        sys.stderr.write(f"page {page_num}: server unreachable ({e})\n")
        return None
    except Exception as e:
        sys.stderr.write(f"page {page_num}: {e}\n")
        return None

    if not data.get("ok"):
        sys.stderr.write(f"page {page_num}: {data.get('message', 'unknown error')}\n")
        return None
    return data.get("text", "")


def main():
    if len(sys.argv) != 2:
        sys.stderr.write("Usage: pdf_parser_vlm.py <file_path>\n")
        sys.exit(1)
    path = sys.argv[1]
    if not os.path.exists(path):
        sys.stderr.write(f"File not found: {path}\n")
        sys.exit(1)

    with tempfile.TemporaryDirectory(prefix="clacky_vlm_") as tmp:
        pages = render_pages(path, tmp)
        if not pages:
            sys.stderr.write("Failed to render PDF pages (is poppler installed?)\n")
            sys.exit(1)

        sys.stderr.write(f"VLM OCR: {len(pages)} page(s) to transcribe...\n")
        chunks = []
        for i, page in enumerate(pages, 1):
            text = transcribe_page(page, i)
            if text is None:
                # Server unreachable / no sidecar — bail so caller falls back.
                sys.exit(1)
            chunks.append(PAGE_SEPARATOR.format(n=i) + text)

        sys.stdout.write("".join(chunks).strip())


if __name__ == "__main__":
    main()
