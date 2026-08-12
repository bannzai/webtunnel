#!/bin/bash
# 指定時間だけジョブを維持する。CDP が応答しなくなったら維持する意味がないため終了する。
# 高負荷時の一時的なストールを殺さないよう、連続 MAX_FAILS 回失敗した時だけ停止と判定する。
# WEBTUNNEL_DEV_PID が設定されている場合（start-dev-server.sh が GITHUB_ENV 経由で渡す）は
# dev サーバのプロセスも監視し、死んでいたら終了する（動作確認の対象が消えたセッションを維持しない）。
# 途中で止める場合はローカルから: gh run cancel <run-id> -R <workflow を動かしている repo>
# usage: keepalive.sh <duration-minutes> [cdp-port]（ポート省略時は 9222）
set -euo pipefail

DURATION_MINUTES="${1:?usage: keepalive.sh <duration-minutes> [cdp-port]}"
PORT="${2:-9222}"
END=$(( $(date +%s) + DURATION_MINUTES * 60 ))
WORK="${RUNNER_TEMP:-$(pwd)/tmp}"
MAX_FAILS=4
FAILS=0

echo "セッション維持: ${DURATION_MINUTES} 分 (CDP port: ${PORT}${WEBTUNNEL_DEV_PID:+, dev server PID: ${WEBTUNNEL_DEV_PID}})"
while [ "$(date +%s)" -lt "$END" ]; do
  if [ -n "${WEBTUNNEL_DEV_PID:-}" ] && ! kill -0 "$WEBTUNNEL_DEV_PID" 2>/dev/null; then
    echo "dev サーバのプロセスが終了したためセッションを終了する" >&2
    if [ -f "${WORK}/webtunnel-dev-server.log" ]; then
      echo "--- dev サーバのログ末尾 ---" >&2
      tail -n 60 "${WORK}/webtunnel-dev-server.log" >&2
    fi
    exit 1
  fi
  if curl -s -m 10 "http://127.0.0.1:${PORT}/json/version" >/dev/null; then
    FAILS=0
  else
    FAILS=$((FAILS + 1))
    echo "CDP :${PORT} 無応答 (${FAILS}/${MAX_FAILS}) $(date '+%H:%M:%S')" >&2
    if [ "$FAILS" -ge "$MAX_FAILS" ]; then
      echo "CDP が応答しなくなったためセッションを終了する" >&2
      # 原因調査用に Chromium のログ末尾を残す（start-chromium.sh と同じログパス）
      if [ -f "${WORK}/chrome.log" ]; then
        echo "--- chrome.log 末尾 ---" >&2
        tail -n 60 "${WORK}/chrome.log" >&2
      fi
      exit 1
    fi
  fi
  sleep 15
done
echo "予定時間（${DURATION_MINUTES} 分）に達したためセッションを終了する"
