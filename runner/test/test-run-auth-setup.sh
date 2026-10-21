#!/usr/bin/env bash
# runner/run-auth-setup.sh が、セットアップスクリプトの終了後に、復号した資格情報を環境に持ったまま
# 残ったプロセスだけを止めることを検証する。/proc の environ を読む処理のため Linux でだけ実行する。
# agent-browser は PATH 上のスタブに差し替え、npm install を走らせない。
set -uo pipefail

if [ ! -d /proc/self ]; then
  echo "[SKIP] /proc の無い環境（Linux の runner でだけ検証する）"
  exit 0
fi

SCRIPT=$(cd "$(dirname "$0")/.." && pwd -P)/run-auth-setup.sh
TMP=$(mktemp -d)
cleanup() {
  local pidfile
  for pidfile in "$TMP"/*.pid; do
    [ -f "$pidfile" ] && kill -9 "$(cat "$pidfile")" 2>/dev/null
  done
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

# プロセスの生死を返す。回収前の zombie は止まったものとして扱う
liveness() {
  local pid=$1
  kill -0 "$pid" 2>/dev/null && [ "$(awk '{print $3}' "/proc/${pid}/stat" 2>/dev/null)" != "Z" ] && echo alive || echo dead
}

# SIGKILL の後、init が回収するまでの間を最大 5 秒待ってから生死を返す
liveness_after_kill() {
  for _ in $(seq 1 50); do
    [ "$(liveness "$1")" = dead ] && break
    sleep 0.1
  done
  liveness "$1"
}

cat > "$TMP/agent-browser" <<'EOF'
#!/usr/bin/env bash
echo "agent-browser stub"
EOF
chmod +x "$TMP/agent-browser"

# 資格情報を環境に持ったまま切り離す常駐プロセスと、資格情報を外して切り離す常駐プロセスを起動する
cat > "$TMP/setup.sh" <<'EOF'
#!/usr/bin/env bash
setsid bash -c 'echo $$ > "$1"; exec sleep 300' _ "$PIDDIR/holder.pid" < /dev/null > /dev/null 2>&1 &
env -u WEBTUNNEL_TEST_SECRET setsid bash -c 'echo $$ > "$1"; exec sleep 300' _ "$PIDDIR/clean.pid" < /dev/null > /dev/null 2>&1 &
for _ in $(seq 1 50); do
  [ -s "$PIDDIR/holder.pid" ] && [ -s "$PIDDIR/clean.pid" ] && exit 0
  sleep 0.1
done
exit 1
EOF

run_setup() {
  local auth_env=$1
  : > "$TMP/summary.md"
  rm -f "$TMP"/*.pid
  PATH="$TMP:$PATH" PIDDIR="$TMP" SETUP_SCRIPT="$TMP/setup.sh" WEBTUNNEL_AUTH_ENV="$auth_env" \
    GITHUB_STEP_SUMMARY="$TMP/summary.md" RUNNER_TEMP="$TMP" bash "$SCRIPT" > "$TMP/out.log" 2>&1
}

# 他のテストの実行と値が衝突しないよう、実行ごとの乱数を値に入れる
SECRET_VALUE="webtunnel-test-${RANDOM}${RANDOM}"
# セットアップの前からある、同じ KEY=VALUE を環境に持つプロセス（runner の既存の環境と一致する値の代わり）
WEBTUNNEL_TEST_SECRET="$SECRET_VALUE" sleep 300 &
PRE_EXISTING_PID=$!
run_setup "$(printf 'WEBTUNNEL_TEST_SECRET=%s\n' "$SECRET_VALUE" | base64 | tr -d '\n')"
assert "資格情報ありで run-auth-setup.sh が成功する" 0 $?
assert "資格情報を環境に持つ常駐プロセスは止まる" dead "$(liveness_after_kill "$(cat "$TMP/holder.pid")")"
assert "資格情報を外した常駐プロセスは残る" alive "$(liveness "$(cat "$TMP/clean.pid")")"
assert "セットアップの前からあるプロセスは同じ KEY=VALUE を持っていても止めない" alive "$(liveness "$PRE_EXISTING_PID")"
kill -9 "$PRE_EXISTING_PID" 2>/dev/null
assert "止めたことを summary に警告する" 1 "$(grep -c '残ったプロセスを止めた' "$TMP/summary.md")"
assert "資格情報の値を出力しない" 0 "$(cat "$TMP/out.log" "$TMP/summary.md" | grep -c "$SECRET_VALUE")"
kill -9 "$(cat "$TMP/clean.pid")" 2>/dev/null

run_setup ""
assert "資格情報なしで run-auth-setup.sh が成功する" 0 $?
assert "資格情報なしでは常駐プロセスを止めない" alive "$(liveness "$(cat "$TMP/holder.pid")")"
assert "資格情報なしでは警告しない" 0 "$(grep -c '残ったプロセスを止めた' "$TMP/summary.md")"

echo "PASS: ${PASS} / FAIL: ${FAIL}"
[ "$FAIL" -eq 0 ]
