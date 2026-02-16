#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Run a looping "live channel" HLS stream:
  - video: playlist.txt (concat demuxer, looped forever)
  - audio: YouTube live stream URL (audio only via yt-dlp)

This script is separate from run_hls.sh so you can keep using file-based audio.

Usage:
  ./run_hls_youtube_audio.sh --youtube-url URL [--video-playlist FILE] [--hls-dir DIR]

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
EOF
}

root_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

video_playlist="${root_dir}/playlist.txt"
hls_dir="${root_dir}/hls"
youtube_url=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --youtube-url) youtube_url="$2"; shift 2 ;;
    --video-playlist) video_playlist="$2"; shift 2 ;;
    --hls-dir) hls_dir="$2"; shift 2 ;;
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

out_m3u8="${hls_dir%/}/live.m3u8"
seg_pat="${hls_dir%/}/seg_%06d.ts"

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

while true; do
  echo "Resolving YouTube audio URL..."
  if ! audio_url="$(resolve_audio_url)"; then
    echo "Failed to resolve YouTube audio URL; retrying in ${restart_delay}s..." >&2
    sleep "$restart_delay"
    continue
  fi

  echo "Starting ffmpeg with YouTube audio..."
  ffmpeg \
    -hide_banner -loglevel info \
    -re -stream_loop -1 -f concat -safe 0 -i "$video_playlist" \
    -reconnect 1 -reconnect_streamed 1 -reconnect_on_network_error 1 \
    -reconnect_on_http_error 4xx,5xx -reconnect_delay_max 5 \
    -thread_queue_size 1024 -i "$audio_url" \
    -map 0:v:0 -map 1:a:0 \
    -c:v libx264 -preset "$preset" -crf "$crf" -pix_fmt yuv420p \
    -g "$gop" -keyint_min "$gop" -sc_threshold 0 \
    -c:a aac -b:a "$audio_bitrate" -ac "$audio_ch" -ar "$audio_sr" \
    -af "aresample=async=1:first_pts=0" \
    -f hls -hls_time "$hls_time" -hls_list_size "$hls_list_size" \
    -hls_flags delete_segments+append_list+independent_segments \
    -hls_segment_filename "$seg_pat" \
    "$out_m3u8" || true

  echo "ffmpeg exited; refreshing YouTube URL and restarting in ${restart_delay}s..."
  sleep "$restart_delay"
done
