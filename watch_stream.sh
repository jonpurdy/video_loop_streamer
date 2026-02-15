#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Watch video+audio directories and restart the stream when anything changes.

This uses a simple polling signature (path + size + mtime), so it has zero deps on macOS.

Usage:
  scripts/watch_stream.sh [--mode hls|vlc_ts] [--interval SECONDS]
                          [--video-dir DIR] [--audio-dir DIR]
                          [--recursive] [--shuffle]
                          [--hls-dir DIR]

Defaults:
  --mode      hls
  --interval  2
  --video-dir repo root
  --audio-dir repo root/audio
  --hls-dir   repo root/hls

Notes:
  - For faster browser startup, try: HLS_TIME=2 HLS_LIST_SIZE=4 scripts/watch_stream.sh
EOF
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root_dir="${script_dir}"

mode="hls"
interval="2"
video_dir="${root_dir}"
audio_dir="${root_dir}/audio"
hls_dir="${root_dir}/hls"
recursive="0"
shuffle="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --mode) mode="$2"; shift 2 ;;
    --interval) interval="$2"; shift 2 ;;
    --video-dir) video_dir="$2"; shift 2 ;;
    --audio-dir) audio_dir="$2"; shift 2 ;;
    --hls-dir) hls_dir="$2"; shift 2 ;;
    --recursive) recursive="1"; shift 1 ;;
    --shuffle) shuffle="1"; shift 1 ;;
    *) echo "Unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$mode" in
  hls|vlc_ts) ;;
  *) echo "Invalid --mode: $mode (use hls or vlc_ts)" >&2; exit 2 ;;
esac

command -v python3 >/dev/null 2>&1 || { echo "python3 not found in PATH" >&2; exit 127; }

child_pid=""

cleanup() {
  if [[ -n "${child_pid}" ]] && kill -0 "${child_pid}" >/dev/null 2>&1; then
    kill "${child_pid}" >/dev/null 2>&1 || true
    wait "${child_pid}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

signature() {
  VIDEO_DIR="$video_dir" AUDIO_DIR="$audio_dir" RECURSIVE="$recursive" python3 - <<'PY'
import hashlib
import os
from pathlib import Path

video_dir = Path(os.environ["VIDEO_DIR"]).expanduser()
audio_dir = Path(os.environ["AUDIO_DIR"]).expanduser()
recursive = os.environ.get("RECURSIVE", "0") == "1"

video_exts = {".mp4", ".m4v", ".mov", ".mkv"}
audio_exts = {".m4a", ".mp3", ".aac", ".wav", ".flac", ".ogg", ".opus"}

def collect(dir_path: Path, exts: set[str]) -> list[Path]:
    if not dir_path.exists():
        return []
    it = dir_path.rglob("*") if recursive else dir_path.iterdir()
    files = [p for p in it if p.is_file() and p.suffix.lower() in exts]
    files.sort(key=lambda p: str(p).lower())
    return files

items = []
for p in collect(video_dir, video_exts) + collect(audio_dir, audio_exts):
    try:
        st = p.stat()
        items.append(f"{p.resolve()}\t{st.st_size}\t{int(st.st_mtime)}")
    except FileNotFoundError:
        # File changed while scanning; caller will rescan next tick.
        pass

h = hashlib.sha256()
for line in items:
    h.update(line.encode("utf-8", "replace"))
    h.update(b"\n")

print(h.hexdigest())
PY
}

start_stream() {
  echo "Rebuilding playlists…"
  args=(--video-dir "$video_dir" --audio-dir "$audio_dir")
  [[ "$recursive" == "1" ]] && args+=(--recursive)
  [[ "$shuffle" == "1" ]] && args+=(--shuffle)
  bash "${root_dir}/build_playlists.sh" "${args[@]}"

  echo "Starting stream (mode=${mode})…"
  if [[ "$mode" == "hls" ]]; then
    bash "${root_dir}/run_hls.sh" --hls-dir "$hls_dir" &
  else
    bash "${root_dir}/run_vlc_http_ts.sh" &
  fi
  child_pid="$!"
}

prev_sig="$(signature)"
start_stream

while true; do
  sleep "$interval"

  # If ffmpeg died (bad file, missing codec, etc), restart it.
  if [[ -n "${child_pid}" ]] && ! kill -0 "${child_pid}" >/dev/null 2>&1; then
    echo "Stream process exited; restarting…"
    start_stream
    prev_sig="$(signature)"
    continue
  fi

  new_sig="$(signature)"
  if [[ "$new_sig" != "$prev_sig" ]]; then
    echo "Detected change; restarting stream…"
    cleanup
    prev_sig="$new_sig"
    start_stream
  fi
done
