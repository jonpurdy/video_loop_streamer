# Quick Start

Put video files in the repo root.  
For file-audio mode, put audio files in `audio/`.

## File Audio + Video

Terminal 1:
```bash
bash ./build_playlists.sh
bash ./run_hls.sh
```

Terminal 2:
```bash
caddy file-server --listen :8080 --root .
```

## YouTube Live Audio + Video

Terminal 1:
```bash
bash ./build_playlists.sh
bash ./run_hls_youtube_audio.sh --youtube-url "https://www.youtube.com/live/_k-5U7IeK8g"
```

Optional (cap output to 1080p, keep random first video):
```bash
bash ./run_hls_youtube_audio.sh --youtube-url "https://www.youtube.com/live/_k-5U7IeK8g" --max-height 1080 --random-start 1
```

Terminal 2:
```bash
caddy file-server --listen :8080 --root .
```

## Open Stream

- Browser player: `http://<lan-ip>:8080/index.html`
- VLC / Apple TV VLC: `http://<lan-ip>:8080/hls/live.m3u8`
