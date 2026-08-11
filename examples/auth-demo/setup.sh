#!/bin/bash
# 「ログイン済み状態でセッションを開始する」経路の検証用セットアップスクリプト兼サンプル。
# runner の localhost にログイン必須のデモサーバを立て、agent-browser を CDP 経由で
# 動かしてフォームログインし、保護されたページを開いた状態でセッションを開始させる。
#
# run-auth-setup.sh から次の環境で呼ばれる:
#   - cwd: caller リポジトリの workspace ルート
#   - WEBTUNNEL_CDP_URL: 起動済み Chromium の CDP エンドポイント
#   - secret WEBTUNNEL_AUTH_ENV に書いた KEY=VALUE がそのまま環境変数として入る
set -euo pipefail

: "${WEBTUNNEL_CDP_URL:?WEBTUNNEL_CDP_URL が未設定（run-auth-setup.sh から実行する）}"
: "${WEBTUNNEL_DEMO_USERNAME:?WEBTUNNEL_DEMO_USERNAME が未設定（secret WEBTUNNEL_AUTH_ENV を確認する）}"
: "${WEBTUNNEL_DEMO_PASSWORD:?WEBTUNNEL_DEMO_PASSWORD が未設定（secret WEBTUNNEL_AUTH_ENV を確認する）}"

PORT="${WEBTUNNEL_DEMO_PORT:-8123}"
# localhost は ::1 に解決されうる一方サーバは 127.0.0.1 で listen するため、URL は IP で固定する
BASE_URL="http://127.0.0.1:${PORT}"
WORK="${RUNNER_TEMP:-$(pwd)/tmp}"
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$WORK"

# すでに listen していれば起動し直さない（冪等）
if ! curl -fs -m 2 -o /dev/null "${BASE_URL}/login"; then
  # セッション中はローカルの agent-browser から触るため、この step の後も生かしておく
  WEBTUNNEL_DEMO_PORT="$PORT" nohup python3 "${HERE}/server.py" >"$WORK/auth-demo-server.log" 2>&1 &
  for _ in $(seq 1 20); do
    curl -fs -m 2 -o /dev/null "${BASE_URL}/login" && break
    sleep 1
  done
fi
curl -fsS -m 2 -o /dev/null "${BASE_URL}/login" || {
  echo "デモサーバが起動しない" >&2
  cat "$WORK/auth-demo-server.log" >&2
  exit 1
}

# add-mask が効いていること（誤って出力しても Actions ログでは *** になること）を
# 実際の run で確認するためのデモ専用の出力。実アプリの setup.sh には書かない
if [ "${WEBTUNNEL_DEMO_MASK_CHECK:-}" = "1" ]; then
  echo "マスク確認 (Actions ログでは伏字になる): ${WEBTUNNEL_DEMO_PASSWORD}"
fi

# パスワードは引数として渡すため runner のプロセス一覧には現れる。使い捨ての単一テナント VM で、
# かつ Actions ログでは add-mask により伏字になるため許容する（PROJECT.md「認証情報の受け渡し」参照）
ab() { agent-browser --cdp "$WEBTUNNEL_CDP_URL" "$@"; }

ab open "${BASE_URL}/login"
ab fill '#username' "$WEBTUNNEL_DEMO_USERNAME"
ab fill '#password' "$WEBTUNNEL_DEMO_PASSWORD"
ab click '#submit'
ab wait '#authenticated'
echo "ログイン完了: ${BASE_URL} を保護されたページで開いた"
