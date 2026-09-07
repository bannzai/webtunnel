#!/usr/bin/env bash
# local/webtunnel の up が、オプションを workflow_dispatch の input（-f）へ正しく写すことを検証する。
# gh と tailscale は PATH 上のスタブに差し替え、dispatch されるはずの引数を観測する。
set -uo pipefail

CLI=$(cd "$(dirname "$0")/.." && pwd -P)/webtunnel
TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; }
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

# tailnet に誰もいない状態（session_ip が空）を作る
cat > "$TMP/tailscale" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
# run list は空（起動中の run なし）、workflow run は受け取った引数を記録する
cat > "$TMP/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "workflow run") printf '%s\n' "$@" > "${GH_STUB_LOG}" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TMP/tailscale" "$TMP/gh"

# up を実行し、gh workflow run に渡った引数を 1 行 1 引数で返す
dispatched_args() {
  GH_STUB_LOG="$TMP/dispatch.log" PATH="$TMP:$PATH" bash "$CLI" up "$@" >/dev/null 2>&1
  cat "$TMP/dispatch.log"
}

args=$(dispatched_args dev --software-webgl)
assert "--software-webgl は software_webgl=true を送る" "1" "$(printf '%s\n' "$args" | grep -c -x 'software_webgl=true')"
assert "--software-webgl でも session / duration_minutes は送る" "2" "$(printf '%s\n' "$args" | grep -c -E -x 'session=dev|duration_minutes=60')"

args=$(dispatched_args dev)
assert "既定では software_webgl を送らない（宣言しない caller workflow で dispatch を拒否させない）" "0" "$(printf '%s\n' "$args" | grep -c 'software_webgl')"

args=$(dispatched_args dev --no-record --software-webgl --duration 10)
assert "他のオプションと併用できる" "3" "$(printf '%s\n' "$args" | grep -c -E -x 'record=false|software_webgl=true|duration_minutes=10')"

out=$(GH_STUB_LOG="$TMP/dispatch.log" PATH="$TMP:$PATH" bash "$CLI" up dev --unknown-option 2>&1)
code=$?
assert "不明なオプションは異常終了する" "1" "$code"
case "$out" in
  *"不明なオプション"*) assert "不明なオプションの理由を出力する" "found" "found" ;;
  *) assert "不明なオプションの理由を出力する" "found" "missing: ${out}" ;;
esac

# --- up --wait 後の診断と、待機中の GitHub API 失敗の扱い ---------------------------------------
# curl スタブ: CDP の /json/version が応答する
cat > "$TMP/curl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
# 診断スクリプトのスタブ: 呼ばれた引数を記録する
cat > "$TMP/doctor.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${DOCTOR_STUB_LOG}"
echo "ALL_OK"
EOF
# tailscale スタブ: up が「tailnet に無い → dispatch → wait → ready」の経路を通るよう、
# 最初の呼び出しは空、2 回目以降は webtunnel-dev の IP を返す（呼び出し回数を TS_STUB_COUNT_FILE で数える）
cat > "$TMP/tailscale" <<'EOF'
#!/usr/bin/env bash
count_file="${TS_STUB_COUNT_FILE:?}"
n=$(cat "$count_file" 2>/dev/null || echo 0)
echo $((n + 1)) > "$count_file"
[ "$n" -ge 1 ] && printf '%s webtunnel-%s linux -\n' "100.64.0.1" "dev"
exit 0
EOF
chmod +x "$TMP/curl" "$TMP/doctor.sh" "$TMP/tailscale"

run_up_wait() {
  rm -f "$TMP/ts-count" "$TMP/doctor.log"
  TS_STUB_COUNT_FILE="$TMP/ts-count" DOCTOR_STUB_LOG="$TMP/doctor.log" GH_STUB_LOG="$TMP/dispatch.log" \
    WEBTUNNEL_DOCTOR="$TMP/doctor.sh" WEBTUNNEL_WAIT_INTERVAL=0 PATH="$TMP:$PATH" "$@" \
    bash "$CLI" up dev --wait "${UP_EXTRA[@]}" 2>&1
}

UP_EXTRA=(--software-webgl)
out=$(run_up_wait)
code=$?
assert "up --wait --software-webgl は ready 後も exit 0" "0" "$code"
assert "up --wait --software-webgl は ready 後に診断を 1 回呼ぶ" "1" "$( [ -f "$TMP/doctor.log" ] && echo 1 || echo 0 )"
assert "診断には --session <session> と --skip-input を渡す（タイトル画面を進めない）" "3" "$(grep -c -E -x -e '--session' -e 'dev' -e '--skip-input' "$TMP/doctor.log" 2>/dev/null || echo 0)"
case "$out" in
  *"段階別診断"*) assert "診断の見出しを出力する" "found" "found" ;;
  *) assert "診断の見出しを出力する" "found" "missing: ${out}" ;;
esac

UP_EXTRA=()
out=$(run_up_wait)
assert "--software-webgl 無しの up --wait は診断を呼ばない" "0" "$( [ -f "$TMP/doctor.log" ] && echo 1 || echo 0 )"

UP_EXTRA=(--software-webgl)
out=$(run_up_wait env WEBTUNNEL_NO_DOCTOR=1)
assert "WEBTUNNEL_NO_DOCTOR=1 なら診断を呼ばない" "0" "$( [ -f "$TMP/doctor.log" ] && echo 1 || echo 0 )"

# 診断が失敗しても up は失敗にしない
cat > "$TMP/doctor.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${DOCTOR_STUB_LOG}"
echo "FAILED_STAGE=webgl2"
exit 1
EOF
out=$(run_up_wait)
code=$?
assert "診断が NG でも up --wait は exit 0（セッションは起動している）" "0" "$code"
case "$out" in
  *"失敗した段階"*) assert "診断 NG の案内を出力する" "found" "found" ;;
  *) assert "診断 NG の案内を出力する" "found" "missing: ${out}" ;;
esac

# 待機中に GitHub API が失敗しても「run が無い」と誤報せず待機を続け、ready で終わる
cat > "$TMP/tailscale" <<'EOF'
#!/usr/bin/env bash
count_file="${TS_STUB_COUNT_FILE:?}"
n=$(cat "$count_file" 2>/dev/null || echo 0)
echo $((n + 1)) > "$count_file"
# 6 回目以降で ready（それまでは run 存在チェック (4 回目〜) が走る）
[ "$n" -ge 6 ] && printf '%s webtunnel-%s linux -\n' "100.64.0.1" "dev"
exit 0
EOF
cat > "$TMP/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "workflow run") printf '%s\n' "$@" > "${GH_STUB_LOG}" ;;
  "run list") exit 1 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TMP/tailscale" "$TMP/gh"
UP_EXTRA=()
out=$(run_up_wait)
code=$?
assert "待機中の GitHub API 失敗では run 不在と判断せず ready まで待つ" "0" "$code"
case "$out" in
  *"GitHub API"*) assert "GitHub API の失敗を run 不在と区別して出力する" "found" "found" ;;
  *) assert "GitHub API の失敗を run 不在と区別して出力する" "found" "missing: ${out}" ;;
esac
case "$out" in
  *"run が存在しない"*) assert "GitHub API の失敗を run 不在として誤報しない" "not-found" "found" ;;
  *) assert "GitHub API の失敗を run 不在として誤報しない" "not-found" "not-found" ;;
esac

# run 一覧が空（取得は成功）なら run 不在として終了する
cat > "$TMP/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "workflow run") printf '%s\n' "$@" > "${GH_STUB_LOG}" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TMP/gh"
out=$(run_up_wait)
code=$?
assert "run 一覧が空なら run 不在として exit 1" "1" "$code"
case "$out" in
  *"run が存在しない"*) assert "run 不在の理由を出力する" "found" "found" ;;
  *) assert "run 不在の理由を出力する" "found" "missing: ${out}" ;;
esac

echo ""
echo "PASS: ${PASS} / FAIL: ${FAIL}"
[ "$FAIL" -eq 0 ]
