#!/bin/bash
# ffmpeg の x11grab で Xvfb の画面を録画する。stop-recording.sh が SIGINT で停止する。
# ジョブが猶予なく殺されても途中まで再生できるよう fragmented MP4 で書き出す。
# env: DISPLAY / WEBTUNNEL_WINDOW_SIZE（start-chromium.sh が GITHUB_ENV 経由で設定）
set -euo pipefail

WORK="${RUNNER_TEMP:-$(pwd)/tmp}"
OUT="$WORK/webtunnel-recording.mp4"
SIZE="${WEBTUNNEL_WINDOW_SIZE:-1280x800}"

command -v ffmpeg >/dev/null 2>&1 || {
  sudo apt-get update -qq
  sudo apt-get install -y -qq ffmpeg
}

# 動作確認の記録用途のため低フレームレートで容量を抑える
nohup ffmpeg -loglevel warning \
  -f x11grab -framerate 5 -video_size "$SIZE" -i "$DISPLAY" \
  -c:v libx264 -preset veryfast -pix_fmt yuv420p \
  -movflags +frag_keyframe+empty_moov \
  -y "$OUT" >"$WORK/ffmpeg.log" 2>&1 &
echo "$!" > "$WORK/ffmpeg.pid"

sleep 2
kill -0 "$(cat "$WORK/ffmpeg.pid")" 2>/dev/null || {
  echo "ffmpeg が起動しない" >&2
  cat "$WORK/ffmpeg.log" >&2
  exit 1
}
echo "recording: $OUT (${SIZE} @5fps)"
