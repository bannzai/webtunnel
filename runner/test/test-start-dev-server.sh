#!/usr/bin/env bash
# runner/start-dev-server.sh が secret WEBTUNNEL_SETUP_ENV を setup_command にだけ環境変数として渡し、
# start_command と、public な Actions ログに出すログ末尾には渡さないことを検証する。
set -uo pipefail

SCRIPT=$(cd "$(dirname "$0")/.." && pwd -P)/start-dev-server.sh
TMP=$(mktemp -d)
cleanup() {
  [ -f "$TMP/dev.pid" ] && kill "$(cat "$TMP/dev.pid")" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

PASS=0
FAIL=0
assert() {
  local name=$1 expected=$2 actual=$3
  if [ "$expected" = "$actual" ]; then
    echo "[PASS] ${name}"
    PASS=$((PASS + 1))
  else
    echo "[FAIL] ${name} (expected: ${expected} / actual: ${actual})"
    FAIL=$((FAIL + 1))
  fi
}

# setup_command / start_command は TMP を cwd にして実行させ、見えた環境変数をファイルに書かせる
run_dev_server() {
  local setup_env=$1 start_command=$2 setup_command=${3:-'env > setup.env'}
  rm -f "$TMP"/*.env "$TMP"/*.log "$TMP/dev.pid"
  GITHUB_WORKSPACE="$TMP" WORKING_DIRECTORY=. RUNNER_TEMP="$TMP/runner-temp" GITHUB_STEP_SUMMARY="$TMP/summary.md" \
    PORT="$PORT" WEBTUNNEL_SETUP_ENV="$setup_env" \
    SETUP_COMMAND="$setup_command" START_COMMAND="$start_command" \
    bash "$SCRIPT" > "$TMP/out.log" 2>&1
}

# 他のテストの実行と値が衝突しないよう、実行ごとの乱数を値に入れる
SECRET_VALUE="webtunnel-test-${RANDOM}${RANDOM}"
ENCODED=$(printf 'WEBTUNNEL_TEST_SETUP_VALUE=%s\n' "$SECRET_VALUE" | base64 | tr -d '\n')
FIRST_PORT=$((20000 + RANDOM % 20000))
PORT=$FIRST_PORT
START_COMMAND='echo $$ > dev.pid; env > start.env; exec python3 -m http.server --bind 127.0.0.1 "$PORT"'

run_dev_server "$ENCODED" "$START_COMMAND"
assert "WEBTUNNEL_SETUP_ENV ありで start-dev-server.sh が成功する" 0 $?
assert "setup_command で KEY=VALUE が環境変数として読める" 1 "$(grep -cx "WEBTUNNEL_TEST_SETUP_VALUE=${SECRET_VALUE}" "$TMP/setup.env")"
assert "setup_command に復号前の secret を渡さない" 0 "$(grep -c '^WEBTUNNEL_SETUP_ENV=' "$TMP/setup.env")"
assert "start_command に復号後の値を渡さない" 0 "$(grep -c '^WEBTUNNEL_TEST_SETUP_VALUE=' "$TMP/start.env")"
assert "start_command に復号前の secret を渡さない" 0 "$(grep -c '^WEBTUNNEL_SETUP_ENV=' "$TMP/start.env")"
assert "値を add-mask に登録する行を step の標準出力に出す" 1 "$(grep -cx "::add-mask::${SECRET_VALUE}" "$TMP/out.log")"
# ::add-mask:: の行は runner が値を伏字にするための登録で、ログには表示されないため除く
assert "値を step の出力に平文で出さない" 0 "$(grep -v '^::add-mask::' "$TMP/out.log" | grep -c "$SECRET_VALUE")"
kill "$(cat "$TMP/dev.pid")" 2>/dev/null

# 止めた dev サーバがポートを離す前に次の実行が始まると、start-dev-server.sh の起動前の応答確認で失敗するため別のポートにする
PORT=$((FIRST_PORT + 1))
run_dev_server "" "$START_COMMAND"
assert "WEBTUNNEL_SETUP_ENV なしで start-dev-server.sh が成功する" 0 $?
assert "WEBTUNNEL_SETUP_ENV なしでは値を渡さない" 0 "$(grep -c '^WEBTUNNEL_TEST_SETUP_VALUE=' "$TMP/setup.env")"
assert "WEBTUNNEL_SETUP_ENV なしでは add-mask を出さない" 0 "$(grep -c '^::add-mask::' "$TMP/out.log")"
kill "$(cat "$TMP/dev.pid")" 2>/dev/null

# マーカーは printf で組み立て、start-dev-server.sh が出す「setup: <コマンド>」の行に一致させない。
# 値から派生した内容（add-mask の対象外）をエラー診断として出力して失敗するビルドの代わり
FAILING_SETUP='echo "derived-$(printf %s "$WEBTUNNEL_TEST_SETUP_VALUE" | rev)"; printf "setup-log-%s\n" marker; exit 1'
run_dev_server "$ENCODED" "" "$FAILING_SETUP"
assert "WEBTUNNEL_SETUP_ENV ありで setup_command が失敗すると start-dev-server.sh も失敗する" 1 $?
assert "WEBTUNNEL_SETUP_ENV ありでは setup_command の失敗ログを step の出力に出さない" 0 "$(grep -c 'setup-log-marker' "$TMP/out.log")"

run_dev_server "" "" 'printf "setup-log-%s\n" marker; exit 1'
assert "WEBTUNNEL_SETUP_ENV なしで setup_command が失敗すると start-dev-server.sh も失敗する" 1 $?
assert "WEBTUNNEL_SETUP_ENV なしでは setup_command の失敗ログ末尾を step の出力に出す" 1 "$(grep -c 'setup-log-marker' "$TMP/out.log")"

# setup_command が値から書き出した設定を dev サーバが診断として出力して終了する場合の代わり
FAILING_START='printf "start-log-%s\n" marker; exit 1'
run_dev_server "$ENCODED" "$FAILING_START" 'true'
assert "WEBTUNNEL_SETUP_ENV ありで dev サーバが終了すると start-dev-server.sh も失敗する" 1 $?
assert "WEBTUNNEL_SETUP_ENV ありでは dev サーバのログ末尾を step の出力に出さない" 0 "$(grep -c 'start-log-marker' "$TMP/out.log")"

run_dev_server "" "$FAILING_START" 'true'
assert "WEBTUNNEL_SETUP_ENV なしでは dev サーバのログ末尾を step の出力に出す" 1 "$(grep -c 'start-log-marker' "$TMP/out.log")"

echo "PASS: ${PASS} / FAIL: ${FAIL}"
[ "$FAIL" -eq 0 ]
