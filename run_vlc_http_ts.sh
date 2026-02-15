#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Stream the looping "channel" directly to VLC as a single HTTP MPEG-TS stream.

This avoids creating HLS segment files, but browsers generally won't play this directly.

Usage:
  scripts/run_vlc_http_ts.sh [--video-playlist FILE] [--audio-playlist FILE] [--bind HOST] [--port PORT]

Defaults:
  --video-playlist  playlist.txt
  --audio-playlist  audio_playlist.txt
  --bind            0.0.0.0
  --port            8090

VLC URL:
  http://<your-lan-ip>:PORT/stream.ts
EOF
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root_dir="${script_dir}"

video_playlist="${root_dir}/playlist.txt"
audio_playlist="${root_dir}/audio_playlist.txt"
bind_host="0.0.0.0"
port="8090"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --video-playlist) video_playlist="$2"; shift 2 ;;
    --audio-playlist) audio_playlist="$2"; shift 2 ;;
    --bind) bind_host="$2"; shift 2 ;;
    --port) port="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v ffmpeg >/dev/null 2>&1 || { echo "ffmpeg not found in PATH" >&2; exit 127; }

[[ -f "$video_playlist" ]] || { echo "Missing video playlist: $video_playlist" >&2; exit 1; }
[[ -f "$audio_playlist" ]] || { echo "Missing audio playlist: $audio_playlist" >&2; exit 1; }

crf="${CRF:-23}"
preset="${PRESET:-veryfast}"
gop="${GOP:-60}"
audio_bitrate="${AUDIO_BITRATE:-160k}"
audio_sr="${AUDIO_SR:-48000}"
audio_ch="${AUDIO_CH:-2}"

url="http://${bind_host}:${port}/stream.ts"

echo "Serving MPEG-TS for VLC at: ${url}"
echo "Open in VLC: http://<your-lan-ip>:${port}/stream.ts"

exec ffmpeg \
  -hide_banner -loglevel info \
  -re -stream_loop -1 -f concat -safe 0 -i "$video_playlist" \
  -re -stream_loop -1 -f concat -safe 0 -i "$audio_playlist" \
  -map 0:v:0 -map 1:a:0 \
  -c:v libx264 -preset "$preset" -crf "$crf" -pix_fmt yuv420p \
  -g "$gop" -keyint_min "$gop" -sc_threshold 0 \
  -c:a aac -b:a "$audio_bitrate" -ac "$audio_ch" -ar "$audio_sr" \
  -af "aresample=async=1:first_pts=0" \
  -f mpegts -muxdelay 0 -muxpreload 0 \
  -listen 1 \
  "$url"
