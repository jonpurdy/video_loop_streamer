#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Run a looping "live channel" HLS stream:
  - video: playlist.txt (concat demuxer)
  - audio: audio_playlist.txt (concat demuxer), replaces video audio

Usage:
  scripts/run_hls.sh [--video-playlist FILE] [--audio-playlist FILE] [--hls-dir DIR]

Env overrides (optional):
  CRF=23
  PRESET=veryfast
  GOP=60
  HLS_TIME=4
  HLS_LIST_SIZE=6
  AUDIO_BITRATE=160k
  AUDIO_SR=48000
  AUDIO_CH=2
EOF
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root_dir="${script_dir}"

video_playlist="${root_dir}/playlist.txt"
audio_playlist="${root_dir}/audio_playlist.txt"
hls_dir="${root_dir}/hls"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --video-playlist) video_playlist="$2"; shift 2 ;;
    --audio-playlist) audio_playlist="$2"; shift 2 ;;
    --hls-dir) hls_dir="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

command -v ffmpeg >/dev/null 2>&1 || { echo "ffmpeg not found in PATH" >&2; exit 127; }

[[ -f "$video_playlist" ]] || { echo "Missing video playlist: $video_playlist" >&2; exit 1; }
[[ -f "$audio_playlist" ]] || { echo "Missing audio playlist: $audio_playlist" >&2; exit 1; }

mkdir -p "$hls_dir"

crf="${CRF:-23}"
preset="${PRESET:-veryfast}"
gop="${GOP:-60}"
hls_time="${HLS_TIME:-4}"
hls_list_size="${HLS_LIST_SIZE:-6}"
audio_bitrate="${AUDIO_BITRATE:-160k}"
audio_sr="${AUDIO_SR:-48000}"
audio_ch="${AUDIO_CH:-2}"

out_m3u8="${hls_dir%/}/live.m3u8"
seg_pat="${hls_dir%/}/seg_%06d.ts"

exec ffmpeg \
  -hide_banner -loglevel info \
  -re -stream_loop -1 -f concat -safe 0 -i "$video_playlist" \
  -re -stream_loop -1 -f concat -safe 0 -i "$audio_playlist" \
  -map 0:v:0 -map 1:a:0 \
  -c:v libx264 -preset "$preset" -crf "$crf" -pix_fmt yuv420p \
  -g "$gop" -keyint_min "$gop" -sc_threshold 0 \
  -c:a aac -b:a "$audio_bitrate" -ac "$audio_ch" -ar "$audio_sr" \
  -af "aresample=async=1:first_pts=0" \
  -f hls -hls_time "$hls_time" -hls_list_size "$hls_list_size" \
  -hls_flags delete_segments+append_list+independent_segments \
  -hls_segment_filename "$seg_pat" \
  "$out_m3u8"
