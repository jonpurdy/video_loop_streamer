#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Run a looping "live channel" HLS stream:
  - video: playlist.txt (file list, looped forever)
  - audio: YouTube live stream URL (audio only via yt-dlp)

This script is separate from run_hls.sh so you can keep using file-based audio.

Usage:
  ./run_hls_youtube_audio.sh --youtube-url URL [--video-playlist FILE] [--hls-dir DIR]
                             [--max-height N] [--random-start 0|1]

Defaults:
  --video-playlist  ./playlist.txt
  --hls-dir         ./hls

Env overrides (optional):
  CRF=23
  PRESET=veryfast
  GOP=60
  HLS_TIME=4
  HLS_LIST_SIZE=6
  AUDIO_BITRATE=160k
  AUDIO_SR=48000
  AUDIO_CH=2
  RESTART_DELAY=2
  YTDLP_FORMAT=bestaudio[ext=m4a]/bestaudio/best
  VIDEO_UDP_PORT=23010
  MAX_HEIGHT=0
  RANDOM_START=1
EOF
}

root_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

video_playlist="${root_dir}/playlist.txt"
hls_dir="${root_dir}/hls"
youtube_url=""
max_height=""
random_start=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --youtube-url) youtube_url="$2"; shift 2 ;;
    --video-playlist) video_playlist="$2"; shift 2 ;;
    --hls-dir) hls_dir="$2"; shift 2 ;;
    --max-height) max_height="$2"; shift 2 ;;
    --random-start) random_start="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$youtube_url" ]] || { echo "Missing required arg: --youtube-url" >&2; exit 2; }

command -v ffmpeg >/dev/null 2>&1 || { echo "ffmpeg not found in PATH" >&2; exit 127; }
command -v yt-dlp >/dev/null 2>&1 || { echo "yt-dlp not found in PATH" >&2; exit 127; }

[[ -f "$video_playlist" ]] || { echo "Missing video playlist: $video_playlist" >&2; exit 1; }

mkdir -p "$hls_dir"

crf="${CRF:-23}"
preset="${PRESET:-veryfast}"
gop="${GOP:-60}"
hls_time="${HLS_TIME:-4}"
hls_list_size="${HLS_LIST_SIZE:-6}"
audio_bitrate="${AUDIO_BITRATE:-160k}"
audio_sr="${AUDIO_SR:-48000}"
audio_ch="${AUDIO_CH:-2}"
restart_delay="${RESTART_DELAY:-2}"
ytdlp_format="${YTDLP_FORMAT:-bestaudio[ext=m4a]/bestaudio/best}"
video_udp_port="${VIDEO_UDP_PORT:-23010}"
max_height="${max_height:-${MAX_HEIGHT:-0}}"
random_start="${random_start:-${RANDOM_START:-1}}"

[[ "$max_height" =~ ^[0-9]+$ ]] || { echo "MAX_HEIGHT/--max-height must be an integer >= 0" >&2; exit 2; }
[[ "$random_start" == "0" || "$random_start" == "1" ]] || { echo "RANDOM_START/--random-start must be 0 or 1" >&2; exit 2; }

out_m3u8="${hls_dir%/}/live.m3u8"
seg_pat="${hls_dir%/}/seg_%06d.ts"

parse_playlist() {
  PLAYLIST_PATH="$1" python3 - <<'PY'
import os
from pathlib import Path

path = Path(os.environ["PLAYLIST_PATH"])
for raw in path.read_text(encoding="utf-8").splitlines():
    raw = raw.strip()
    if not raw or raw.startswith("#"):
        continue
    if not raw.startswith("file "):
        continue
    s = raw[5:].strip()
    if len(s) >= 2 and s[0] == "'" and s[-1] == "'":
        s = s[1:-1]
    s = s.replace("\\\\'", "'").replace("\\\\\\\\", "\\\\")
    print(s)
PY
}

videos=()
while IFS= read -r p; do videos+=("$p"); done < <(parse_playlist "$video_playlist")
if [[ "${#videos[@]}" -eq 0 ]]; then
  echo "No video entries parsed from $video_playlist" >&2
  exit 1
fi

start_index=0
if [[ "$random_start" == "1" && "${#videos[@]}" -gt 1 ]]; then
  start_index=$(( RANDOM % ${#videos[@]} ))
  echo "Random start enabled; first video index: ${start_index}"
fi

video_pid=""
cleanup() {
  if [[ -n "${video_pid}" ]] && kill -0 "$video_pid" >/dev/null 2>&1; then
    kill "$video_pid" >/dev/null 2>&1 || true
    wait "$video_pid" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

resolve_audio_url() {
  local resolved=""
  local fmt
  local -a formats

  formats=("$ytdlp_format" "bestaudio/best" "best")
  for fmt in "${formats[@]}"; do
    resolved="$(
      yt-dlp \
        --no-warnings \
        --no-playlist \
        --extractor-args "youtube:player_client=ios,web,android" \
        -f "$fmt" \
        -g "$youtube_url" 2>/dev/null \
        | head -n 1 \
        | tr -d '\r'
    )"
    if [[ -n "$resolved" ]]; then
      printf '%s\n' "$resolved"
      return 0
    fi
  done

  return 1
}

run_video_loop() {
  local dest="udp://127.0.0.1:${video_udp_port}?pkt_size=1316"
  local idx="$start_index"
  local v=""
  while true; do
    v="${videos[$idx]}"
    idx=$(( (idx + 1) % ${#videos[@]} ))
    [[ -f "$v" ]] || continue

    cmd=(
      ffmpeg
      -hide_banner -loglevel warning
      -re -i "$v"
      -map 0:v:0 -an
      -c:v libx264 -preset "$preset" -crf "$crf" -pix_fmt yuv420p
      -g "$gop" -keyint_min "$gop" -sc_threshold 0
    )

    if [[ "$max_height" -gt 0 ]]; then
      cmd+=(-vf "scale=-2:${max_height}")
    fi

    cmd+=(
      -f mpegts -muxdelay 0 -muxpreload 0
      "$dest"
    )

    "${cmd[@]}" || true
  done
}

while true; do
  echo "Resolving YouTube audio URL..."
  if ! audio_url="$(resolve_audio_url)"; then
    echo "Failed to resolve YouTube audio URL; retrying in ${restart_delay}s..." >&2
    sleep "$restart_delay"
    continue
  fi

  echo "Starting ffmpeg with YouTube audio..."
  run_video_loop &
  video_pid="$!"

  ffmpeg \
    -hide_banner -loglevel info \
    -thread_queue_size 2048 -i "udp://127.0.0.1:${video_udp_port}?fifo_size=2000000&overrun_nonfatal=1" \
    -reconnect 1 -reconnect_streamed 1 -reconnect_on_network_error 1 \
    -reconnect_on_http_error 4xx,5xx -reconnect_delay_max 5 \
    -thread_queue_size 1024 -i "$audio_url" \
    -map 0:v:0 -map 1:a:0 \
    -c:v copy \
    -c:a aac -b:a "$audio_bitrate" -ac "$audio_ch" -ar "$audio_sr" \
    -af "aresample=async=1:first_pts=0" \
    -f hls -hls_time "$hls_time" -hls_list_size "$hls_list_size" \
    -hls_flags delete_segments+append_list+independent_segments \
    -hls_segment_filename "$seg_pat" \
    "$out_m3u8" || true

  if [[ -n "${video_pid}" ]] && kill -0 "$video_pid" >/dev/null 2>&1; then
    kill "$video_pid" >/dev/null 2>&1 || true
    wait "$video_pid" >/dev/null 2>&1 || true
  fi
  video_pid=""

  echo "ffmpeg exited; refreshing YouTube URL and restarting in ${restart_delay}s..."
  sleep "$restart_delay"
done
