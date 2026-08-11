#!/bin/bash
# caller リポジトリの dev サーバを runner の localhost で起動し、応答するまで待つ。
# ポートは PORT 環境変数として両コマンドに渡す（session.yml の port input が SSOT）。
# ログは RUNNER_TEMP に残し、session.yml が artifact にアップロードする。
# env: START_COMMAND（必須）/ SETUP_COMMAND / WORKING_DIRECTORY / PORT / READY_PATH
set -euo pipefail

START_COMMAND="${START_COMMAND:?START_COMMAND が未設定}"
SETUP_COMMAND="${SETUP_COMMAND:-}"
WORKING_DIRECTORY="${WORKING_DIRECTORY:-.}"
PORT="${PORT:-5173}"
READY_PATH="${READY_PATH:-/}"
# 先頭スラッシュ無しで渡されると URL が壊れる（http://127.0.0.1:5173health になる）ため補う
[[ "$READY_PATH" == /* ]] || READY_PATH="/${READY_PATH}"
ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
WORK="${RUNNER_TEMP:-$(pwd)/tmp}"
SETUP_LOG="$WORK/webtunnel-dev-server-setup.log"
LOG="$WORK/webtunnel-dev-server.log"
READY_URL="http://127.0.0.1:${PORT}${READY_PATH}"
mkdir -p "$WORK"

# HTTP ステータスは問わない（応答がある = dev サーバが listen している）
responding() {
  curl -s -o /dev/null -m 3 "$READY_URL"
}

if responding; then
  echo "${READY_URL} はすでに応答している（冪等: 何もしない）"
  exit 0
fi

cd "${ROOT}/${WORKING_DIRECTORY}"
export PORT

if [ -n "$SETUP_COMMAND" ]; then
  echo "setup: ${SETUP_COMMAND}"
  bash -c "$SETUP_COMMAND" >"$SETUP_LOG" 2>&1 || {
    echo "setup_command が失敗。ログ末尾:" >&2
    tail -n 100 "$SETUP_LOG" >&2
    exit 1
  }
fi

echo "start: ${START_COMMAND} (PORT=${PORT})"
nohup bash -c "$START_COMMAND" >"$LOG" 2>&1 &
DEV_PID=$!

for _ in $(seq 1 90); do
  if responding; then
    echo "ready: ${READY_URL}"
    exit 0
  fi
  kill -0 "$DEV_PID" 2>/dev/null || {
    echo "dev サーバのプロセスが終了した。ログ末尾:" >&2
    tail -n 100 "$LOG" >&2
    exit 1
  }
  sleep 2
done
echo "dev サーバが ${READY_URL} で応答しない" >&2
tail -n 100 "$LOG" >&2
exit 1
