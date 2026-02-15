#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Build ffmpeg concat playlists for looping video+audio.

Defaults:
  - video dir: repo root
  - audio dir: repo root/audio
  - outputs:   repo root/playlist.txt and repo root/audio_playlist.txt

Usage:
  scripts/build_playlists.sh [--video-dir DIR] [--audio-dir DIR]
                             [--video-out FILE] [--audio-out FILE]
                             [--recursive] [--shuffle]

Notes:
  - Playlists are in the "concat demuxer" format: file '...'
  - Paths are written as absolute paths to avoid cwd issues.
EOF
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root_dir="${script_dir}"

video_dir="${root_dir}"
audio_dir="${root_dir}/audio"
video_out="${root_dir}/playlist.txt"
audio_out="${root_dir}/audio_playlist.txt"
recursive="0"
shuffle="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --video-dir) video_dir="$2"; shift 2 ;;
    --audio-dir) audio_dir="$2"; shift 2 ;;
    --video-out) video_out="$2"; shift 2 ;;
    --audio-out) audio_out="$2"; shift 2 ;;
    --recursive) recursive="1"; shift 1 ;;
    --shuffle) shuffle="1"; shift 1 ;;
    *) echo "Unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

VIDEO_DIR="$video_dir" AUDIO_DIR="$audio_dir" VIDEO_OUT="$video_out" AUDIO_OUT="$audio_out" RECURSIVE="$recursive" SHUFFLE="$shuffle" python3 - <<'PY'
import os
import random
import sys
from pathlib import Path

video_dir = Path(os.environ["VIDEO_DIR"]).expanduser().resolve()
audio_dir = Path(os.environ["AUDIO_DIR"]).expanduser().resolve()
video_out = Path(os.environ["VIDEO_OUT"]).expanduser().resolve()
audio_out = Path(os.environ["AUDIO_OUT"]).expanduser().resolve()
recursive = os.environ.get("RECURSIVE", "0") == "1"
shuffle = os.environ.get("SHUFFLE", "0") == "1"

video_exts = {".mp4", ".m4v", ".mov", ".mkv"}
audio_exts = {".m4a", ".mp3", ".aac", ".wav", ".flac", ".ogg", ".opus"}

def collect(dir_path: Path, exts: set[str]) -> list[Path]:
    if not dir_path.exists():
        return []
    if recursive:
        candidates = [p for p in dir_path.rglob("*") if p.is_file()]
    else:
        candidates = [p for p in dir_path.iterdir() if p.is_file()]
    out = [p for p in candidates if p.suffix.lower() in exts]
    out.sort(key=lambda p: str(p).lower())
    if shuffle:
        random.shuffle(out)
    return out

def esc_for_concat(path: str) -> str:
    # ffmpeg concat demuxer supports quoted strings; escape backslash and single quote.
    return path.replace("\\\\", "\\\\\\\\").replace("'", "\\\\'")

def write_playlist(paths: list[Path], out_path: Path) -> int:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", encoding="utf-8", newline="\n") as f:
        for p in paths:
            f.write(f"file '{esc_for_concat(str(p))}'\n")
    return len(paths)

videos = collect(video_dir, video_exts)
audios = collect(audio_dir, audio_exts)

vcount = write_playlist(videos, video_out)
acount = write_playlist(audios, audio_out)

print(f"Wrote {vcount} video entries -> {video_out}")
print(f"Wrote {acount} audio entries -> {audio_out}")

if vcount == 0:
    print(f"ERROR: No videos found in {video_dir}", file=sys.stderr)
    sys.exit(1)
if acount == 0:
    print(f"ERROR: No audio files found in {audio_dir}", file=sys.stderr)
    sys.exit(1)
PY
