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

# 127.0.0.1 以外で listen していると Tailscale 参加後に dev サーバが tailnet へ露出する
# （PROJECT.md「dev サーバの起動」）。runner (Linux) には ss が必ずあり、
# ローカル macOS での単体実行時だけスキップされる
assert_loopback_only() {
  command -v ss >/dev/null 2>&1 || return 0
  local exposed
  exposed=$(ss -tln "( sport = :${PORT} )" 2>/dev/null | awk 'NR>1 {print $4}' | grep -vE '^(127\.[0-9.]+|\[::1\]):' || true)
  [ -z "$exposed" ] || {
    echo "dev サーバが loopback 以外で listen している: ${exposed}" >&2
    echo "127.0.0.1 で listen させる（例: vite は server.host、next dev は -H 127.0.0.1）" >&2
    exit 1
  }
}

if responding; then
  assert_loopback_only
  echo "${READY_URL} はすでに応答している（冪等: 何もしない）"
  exit 0
fi

cd "${ROOT}/${WORKING_DIRECTORY}"
export PORT
# id-token: write の job では全 step に OIDC トークン発行用の env が注入される。
# caller のコマンド（依存パッケージの install script を含む）に Tailscale の
# trust credential を使える token の発行能力を渡さない
unset ACTIONS_ID_TOKEN_REQUEST_URL ACTIONS_ID_TOKEN_REQUEST_TOKEN

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
    assert_loopback_only
    # ready 後にプロセスが死んだらセッションを終了させるため keepalive.sh へ引き継ぐ
    [ -z "${GITHUB_ENV:-}" ] || echo "WEBTUNNEL_DEV_PID=${DEV_PID}" >> "$GITHUB_ENV"
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
