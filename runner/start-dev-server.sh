#!/bin/bash
# caller リポジトリのセットアップを実行し、dev サーバを runner の localhost で起動して応答するまで待つ。
# START_COMMAND が空の場合はセットアップだけ実行して終わる（拡張のビルドだけが要るセッション）。
# ポートは PORT 環境変数として両コマンドに渡す（session.yml の port input が SSOT）。
# ログは RUNNER_TEMP に残し、session.yml が artifact にアップロードする。
# secret WEBTUNNEL_SETUP_ENV（base64 の KEY=VALUE 列）は復号して SETUP_COMMAND にだけ環境変数として渡す
# （参照: PROJECT.md「dev サーバの起動」）。
# env: START_COMMAND / SETUP_COMMAND（どちらか必須）/ WORKING_DIRECTORY / PORT / READY_PATH /
#      WEBTUNNEL_SETUP_ENV
set -euo pipefail

# shellcheck source=runner/load-env-secret.sh
source "$(dirname "$0")/load-env-secret.sh"

warn() {
  echo "::warning::$1"
  {
    echo "## ⚠️ セットアップ"
    echo ""
    echo "$1"
  } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
}

START_COMMAND="${START_COMMAND:-}"
SETUP_COMMAND="${SETUP_COMMAND:-}"
[ -n "$START_COMMAND" ] || [ -n "$SETUP_COMMAND" ] || {
  echo "START_COMMAND と SETUP_COMMAND がどちらも未設定" >&2
  exit 1
}
WORKING_DIRECTORY="${WORKING_DIRECTORY:-.}"
PORT="${PORT:-5173}"
READY_PATH="${READY_PATH:-/}"
# 先頭スラッシュ無しで渡されると URL が壊れる（http://127.0.0.1:5173health になる）ため補う
[[ "$READY_PATH" == /* ]] || READY_PATH="/${READY_PATH}"
ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
WORK="${RUNNER_TEMP:-$(pwd)/tmp}"
SETUP_LOG="$WORK/webtunnel-dev-server-setup.log"
# 復号した値を環境に持つ setup_command の出力は、session.yml が artifact に上げる glob
# （webtunnel-dev-server*.log）に掛からない名前に書く。add-mask は artifact のファイル内容を伏字にしないため
if [ -n "${WEBTUNNEL_SETUP_ENV:-}" ]; then
  SETUP_LOG="$WORK/webtunnel-setup-command-with-secret.log"
fi
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

# 冪等にはしない（起動前に応答がある = このポートを別プロセスが握っている）。
# runner は毎回クリーンな VM のため、dev サーバ起動前の応答は想定外。
# ここで成功扱いにすると Chromium が無関係なサービスを開き、DEV_PID も引き継がれず
# 監視されないまま ready になってしまう（PR #10 のレビュー指摘）。
if [ -n "$START_COMMAND" ] && responding; then
  echo "起動前に ${READY_URL} が応答している。ポート ${PORT} を別プロセスが握っている" >&2
  exit 1
fi

cd "${ROOT}/${WORKING_DIRECTORY}"
export PORT

# caller のコマンド（依存パッケージの install script を含む）が GITHUB_ENV 等で後続ステップへ
# BASH_ENV 等を書き込まないよう、GitHub の永続化ファイルを使い捨てファイルへ向ける。
# セキュリティ境界ではない（同一 VM・sudo NOPASSWD のため。PROJECT.md「リポジトリ公開に耐える安全性」の 11 参照）
DECOY_DIR="$WORK/caller-github-files"
mkdir -p "$DECOY_DIR"
# 復号前の secret の生値は caller のコマンドへ渡さない（start_command には復号後の値も渡さない）
caller_env=(env -u WEBTUNNEL_SETUP_ENV
  GITHUB_ENV="$DECOY_DIR/env"
  GITHUB_PATH="$DECOY_DIR/path"
  GITHUB_OUTPUT="$DECOY_DIR/output"
  GITHUB_STATE="$DECOY_DIR/state")

if [ -n "$SETUP_COMMAND" ]; then
  echo "setup: ${SETUP_COMMAND}"
  # 復号した値の export をサブシェルに閉じ、start_command へ引き継がない。
  # add-mask の行は step の標準出力に出す必要があるため、出力をログへ向けるのは復号の後
  (
    if [ -n "${WEBTUNNEL_SETUP_ENV:-}" ]; then
      load_env_secret WEBTUNNEL_SETUP_ENV "$WEBTUNNEL_SETUP_ENV"
    fi
    exec "${caller_env[@]}" bash -c "$SETUP_COMMAND" >"$SETUP_LOG" 2>&1
  ) || {
    echo "setup_command が失敗。ログ末尾:" >&2
    tail -n 100 "$SETUP_LOG" >&2
    exit 1
  }
fi

if [ -z "$START_COMMAND" ]; then
  echo "start_command が空のため dev サーバは起動しない（セットアップのみ）"
  exit 0
fi

echo "start: ${START_COMMAND} (PORT=${PORT})"
nohup "${caller_env[@]}" bash -c "$START_COMMAND" >"$LOG" 2>&1 &
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
