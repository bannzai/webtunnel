#!/bin/bash
# start-recording.sh の ffmpeg を SIGINT で止め、MP4 をファイナライズする。
# 録画していない・すでに停止している場合は何もしない（冪等）。
set -euo pipefail

WORK="${RUNNER_TEMP:-$(pwd)/tmp}"
PID_FILE="$WORK/ffmpeg.pid"

[ -f "$PID_FILE" ] || { echo "録画は開始されていない（何もしない）"; exit 0; }
PID="$(cat "$PID_FILE")"

if kill -0 "$PID" 2>/dev/null; then
  kill -INT "$PID"
  # SIGINT 後のファイナライズ完了（プロセス終了）を待つ
  for _ in $(seq 1 15); do
    kill -0 "$PID" 2>/dev/null || break
    sleep 1
  done
  kill -0 "$PID" 2>/dev/null && kill -KILL "$PID"
fi

OUT="$WORK/webtunnel-recording.mp4"
if [ -f "$OUT" ]; then
  echo "saved: $OUT ($(du -h "$OUT" | cut -f1))"
else
  echo "録画ファイルが存在しない: $OUT" >&2
  cat "$WORK/ffmpeg.log" >&2 || true
fi
