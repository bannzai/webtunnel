#!/bin/bash
# preview-server.py（MJPEG 配信）を起動し、127.0.0.1:$PREVIEW_PORT が listen するまで待つ。
# すでに listen している場合は何もしない（冪等）。
# bind は 127.0.0.1 のまま（無認証のため）。tailnet への公開は bridge.sh が行う。
# env: PREVIEW_PORT（既定 9100）/ DISPLAY・WEBTUNNEL_WINDOW_SIZE（start-chromium.sh が設定）
set -euo pipefail

PREVIEW_PORT="${PREVIEW_PORT:-9100}"
WORK="${RUNNER_TEMP:-$(pwd)/tmp}"
LOG="$WORK/preview.log"
mkdir -p "$WORK"

if nc -z -w 2 127.0.0.1 "$PREVIEW_PORT" >/dev/null 2>&1; then
  echo "preview はすでに起動している: http://127.0.0.1:${PREVIEW_PORT}"
  exit 0
fi

# 録画を無効にしたセッションでも preview は使うため、ここでも ffmpeg の有無を見る
command -v ffmpeg >/dev/null 2>&1 || {
  sudo apt-get update -qq
  sudo apt-get install -y -qq ffmpeg
}

PREVIEW_PORT="$PREVIEW_PORT" nohup python3 "$(dirname "$0")/preview-server.py" >"$LOG" 2>&1 &

for _ in $(seq 1 30); do
  if nc -z -w 2 127.0.0.1 "$PREVIEW_PORT" >/dev/null 2>&1; then
    echo "preview ready: http://127.0.0.1:${PREVIEW_PORT}"
    exit 0
  fi
  sleep 1
done

echo "preview サーバが起動しない" >&2
cat "$LOG" >&2
exit 1
