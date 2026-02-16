#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Run a looping "live channel" HLS stream without using ffmpeg's concat demuxer.

Why:
  The concat demuxer requires all input files to have matching stream layouts/codecs.
  If you mix H.264 and HEVC (or different track layouts), concat can eventually error with
  "Error splitting the input into NAL units" / "No start code is found".

How:
  - One ffmpeg process loops videos and transcodes each file -> H.264 over local UDP (video-only)
  - One ffmpeg process loops audio files and transcodes each file -> AAC over local UDP (audio-only)
  - One ffmpeg process muxes those two UDP inputs and writes HLS segments

Usage:
  ./run_hls_udp.sh [--video-playlist FILE] [--audio-playlist FILE] [--hls-dir DIR]

Defaults:
  --video-playlist  ./playlist.txt
  --audio-playlist  ./audio_playlist.txt
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
  VIDEO_UDP_PORT=23000
  AUDIO_UDP_PORT=23001
EOF
}

root_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

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
command -v python3 >/dev/null 2>&1 || { echo "python3 not found in PATH" >&2; exit 127; }

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
video_udp_port="${VIDEO_UDP_PORT:-23000}"
audio_udp_port="${AUDIO_UDP_PORT:-23001}"

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
    # Expect: file '...'
    s = raw[5:].strip()
    if len(s) >= 2 and s[0] == "'" and s[-1] == "'":
        s = s[1:-1]
    # Unescape what build_playlists.sh escapes.
    s = s.replace("\\\\'", "'").replace("\\\\\\\\", "\\\\")
    print(s)
PY
}

videos=()
while IFS= read -r p; do videos+=("$p"); done < <(parse_playlist "$video_playlist")
audios=()
while IFS= read -r p; do audios+=("$p"); done < <(parse_playlist "$audio_playlist")

if [[ "${#videos[@]}" -eq 0 ]]; then
  echo "No video entries parsed from $video_playlist" >&2
  exit 1
fi
if [[ "${#audios[@]}" -eq 0 ]]; then
  echo "No audio entries parsed from $audio_playlist" >&2
  exit 1
fi

video_pid=""
audio_pid=""
mux_pid=""

cleanup() {
  for pid in "$video_pid" "$audio_pid" "$mux_pid"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
      kill "$pid" >/dev/null 2>&1 || true
      wait "$pid" >/dev/null 2>&1 || true
    fi
  done
}
trap cleanup EXIT INT TERM

run_video_loop() {
  local dest="udp://127.0.0.1:${video_udp_port}?pkt_size=1316"
  while true; do
    for v in "${videos[@]}"; do
      [[ -f "$v" ]] || continue
      ffmpeg -hide_banner -loglevel warning \
        -re -i "$v" \
        -map 0:v:0 -an \
        -c:v libx264 -preset "$preset" -crf "$crf" -pix_fmt yuv420p \
        -g "$gop" -keyint_min "$gop" -sc_threshold 0 \
        -f mpegts -muxdelay 0 -muxpreload 0 \
        "$dest" || true
    done
  done
}

run_audio_loop() {
  local dest="udp://127.0.0.1:${audio_udp_port}?pkt_size=1316"
  while true; do
    for a in "${audios[@]}"; do
      [[ -f "$a" ]] || continue
      ffmpeg -hide_banner -loglevel warning \
        -re -i "$a" \
        -map 0:a:0 -vn \
        -c:a aac -b:a "$audio_bitrate" -ac "$audio_ch" -ar "$audio_sr" \
        -af "aresample=async=1:first_pts=0" \
        -f mpegts -muxdelay 0 -muxpreload 0 \
        "$dest" || true
    done
  done
}

run_mux_to_hls() {
  local v_in="udp://127.0.0.1:${video_udp_port}?fifo_size=2000000&overrun_nonfatal=1"
  local a_in="udp://127.0.0.1:${audio_udp_port}?fifo_size=2000000&overrun_nonfatal=1"
  exec ffmpeg -hide_banner -loglevel info \
    -thread_queue_size 2048 -i "$v_in" \
    -thread_queue_size 2048 -i "$a_in" \
    -map 0:v:0 -map 1:a:0 \
    -c copy \
    -f hls -hls_time "$hls_time" -hls_list_size "$hls_list_size" \
    -hls_flags delete_segments+append_list+independent_segments \
    -hls_segment_filename "$seg_pat" \
    "$out_m3u8"
}

run_mux_to_hls &
mux_pid="$!"
run_video_loop &
video_pid="$!"
run_audio_loop &
audio_pid="$!"

wait "$mux_pid"

