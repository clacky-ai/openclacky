#!/usr/bin/env bash
# Helpers for stitching multiple Veo clips into one continuous video using the
# "last-frame chaining" technique (method A): the last frame of clip N becomes
# the first frame (image-to-video) of clip N+1, so the seam is visually
# continuous. The agent drives generation via the /api/media/video endpoint;
# this script only does the mechanical ffmpeg steps.
#
# Requires: ffmpeg, ffprobe (both ship with the standard image).
#
# Subcommands:
#   lastframe  <video.mp4> <out.jpg>           extract the final frame (JPEG by default)
#   tob64      <image>                          print base64 (no newlines) to stdout
#   payload    <out.json> <frame.jpg> <dur> <aspect> <output_dir> <prompt> [session_id]
#                                               build an image-to-video JSON body
#                                               for `curl --data @out.json`
#   concat     <out.mp4> <clip1.mp4> [clip2 …]  losslessly join clips in order
#   probe      <video.mp4>                      print "WIDTHxHEIGHT FPS DURATION"
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 not found on PATH"; }

cmd_lastframe() {
  local src="$1" out="$2"
  [[ -f "$src" ]] || die "no such video: $src"
  need ffmpeg; need ffprobe
  # sseof seeks relative to end; -update 1 keeps overwriting so we land on the
  # genuinely last decodable frame regardless of exact timestamp.
  # JPEG (-q:v 3) keeps the base64 ~8x smaller than PNG, which matters because a
  # PNG frame's base64 (~1.5MB) overflows ARG_MAX when inlined into a shell arg.
  ffmpeg -nostdin -loglevel error -y -sseof -0.5 -i "$src" \
    -update 1 -frames:v 1 -q:v 3 "$out"
  [[ -f "$out" ]] || die "failed to extract last frame"
  echo "$out"
}

cmd_tob64() {
  local img="$1"
  [[ -f "$img" ]] || die "no such image: $img"
  base64 < "$img" | tr -d '\n'
}

# Build the image-to-video request body as a file so curl can send it with
# `--data @file`, avoiding "Argument list too long" from inlining base64.
cmd_payload() {
  local out="$1" frame="$2" dur="$3" aspect="$4" odir="$5" prompt="$6" session_id="${7:-}"
  [[ -f "$frame" ]] || die "no such frame: $frame"
  need ffprobe
  local mime b64
  case "$frame" in
    *.png) mime="image/png" ;;
    *)     mime="image/jpeg" ;;
  esac
  b64="$(base64 < "$frame" | tr -d '\n')"
  FRAME_B64="$b64" FRAME_MIME="$mime" P_PROMPT="$prompt" P_DUR="$dur" \
  P_ASPECT="$aspect" P_ODIR="$odir" P_SESSION_ID="$session_id" python3 - "$out" <<'PY'
import json, os, sys
body = {
  "prompt": os.environ["P_PROMPT"],
  "aspect_ratio": os.environ["P_ASPECT"],
  "duration_seconds": int(os.environ["P_DUR"]),
  "output_dir": os.environ["P_ODIR"],
  "image": {"b64_json": os.environ["FRAME_B64"], "mime_type": os.environ["FRAME_MIME"]},
}
if os.environ["P_SESSION_ID"]:
  body["session_id"] = os.environ["P_SESSION_ID"]
open(sys.argv[1], "w").write(json.dumps(body))
PY
  [[ -f "$out" ]] || die "failed to write payload"
  echo "$out"
}

cmd_concat() {
  local out="$1"; shift
  [[ $# -ge 1 ]] || die "concat needs at least one clip"
  need ffmpeg
  local listfile
  listfile="$(mktemp -t veo_concat.XXXXXX)"
  trap 'rm -f "$listfile"' RETURN
  local clip abs
  for clip in "$@"; do
    [[ -f "$clip" ]] || die "no such clip: $clip"
    abs="$(cd "$(dirname "$clip")" && pwd)/$(basename "$clip")"
    printf "file '%s'\n" "$abs" >> "$listfile"
  done
  # Try stream-copy first (fast, lossless); fall back to re-encode if the clips
  # are not bit-compatible for the concat demuxer.
  if ! ffmpeg -nostdin -loglevel error -y -f concat -safe 0 -i "$listfile" \
        -c copy "$out" 2>/dev/null; then
    ffmpeg -nostdin -loglevel error -y -f concat -safe 0 -i "$listfile" \
      -c:v libx264 -pix_fmt yuv420p -c:a aac "$out"
  fi
  echo "$out"
}

cmd_probe() {
  local src="$1"
  [[ -f "$src" ]] || die "no such video: $src"
  need ffprobe
  ffprobe -v error -select_streams v:0 \
    -show_entries stream=width,height,r_frame_rate \
    -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 "$src" \
    | paste -sd' ' -
}

[[ $# -ge 1 ]] || die "usage: $0 {lastframe|tob64|payload|concat|probe} ..."
sub="$1"; shift
case "$sub" in
  lastframe) cmd_lastframe "$@" ;;
  tob64)     cmd_tob64 "$@" ;;
  payload)   cmd_payload "$@" ;;
  concat)    cmd_concat "$@" ;;
  probe)     cmd_probe "$@" ;;
  *)         die "unknown subcommand: $sub" ;;
esac
