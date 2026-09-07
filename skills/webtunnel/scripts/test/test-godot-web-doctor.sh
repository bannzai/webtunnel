#!/usr/bin/env bash
# godot-web-doctor.sh の段階別判定（runner → cdp → http → loaded → webgl2 → shot → input）を、
# gh / curl と godot-web.sh のスタブで検証する。Chromium も GitHub も使わない。
#
# スタブの挙動は環境変数で変える:
#   GH_STUB_RUNS            gh run list が返す行（空なら run 無し）
#   GH_STUB_FAIL=1          gh run list を exit 1 にする（GitHub API の失敗）
#   GH_STUB_WORKFLOW_YAML   gh api contents/... が base64 で返す caller workflow の YAML
#   CURL_STUB_OK=0          curl を exit 1 にする
#   HELPER_STUB_FAIL=<sub>  godot-web.sh のそのサブコマンドを exit 1 にする
#   HELPER_STUB_HREF        status が返す href（既定 about:blank）
#   HELPER_STUB_HTTP_STATUS open / fetch-status が返す HTTP ステータス（既定 200）
#   HELPER_STUB_WEBGL2      wait-started が返す webgl2（既定 true）
#   HELPER_STUB_LOG         スタブが受け取った引数列を追記するファイル（どの段階まで呼ばれたかの検証用）
set -uo pipefail

DOCTOR=$(cd "$(dirname "$0")/.." && pwd -P)/godot-web-doctor.sh
TMP=$(mktemp -d)
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

command -v jq >/dev/null 2>&1 || { echo "UNAVAILABLE: jq が無い (doctor が使う)"; exit 2; }
JQ_DIR=$(dirname "$(command -v jq)")

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
assert_contains() {
  local name=$1 needle=$2 haystack=$3
  case "$haystack" in
    *"$needle"*) assert "$name" "contains" "contains" ;;
    *) assert "$name" "contains:${needle}" "missing (actual: ${haystack})" ;;
  esac
}
assert_not_contains() {
  local name=$1 needle=$2 haystack=$3
  case "$haystack" in
    *"$needle"*) assert "$name" "not-contains:${needle}" "contains (actual: ${haystack})" ;;
    *) assert "$name" "not-contains" "not-contains" ;;
  esac
}

# --- スタブ -----------------------------------------------------------------
STUB_BIN="${TMP}/bin"
mkdir -p "$STUB_BIN"

cat > "${STUB_BIN}/gh" <<'EOF'
#!/usr/bin/env bash
# gh のスタブ。run list はセッションの run 一覧、api は caller workflow の YAML を base64 で返す
case "${1:-}" in
  run)
    # GitHub API の失敗（run が無いのとは区別される）
    if [ "${GH_STUB_FAIL:-0}" = "1" ]; then
      echo "HTTP 503: Service Unavailable" >&2
      exit 1
    fi
    if [ -n "${GH_STUB_RUNS:-}" ]; then
      printf '%s\n' "${GH_STUB_RUNS}"
    fi
    ;;
  api)
    # gh api --jq '.content' と同じく base64 で返す（既定は port: "8000" を宣言した caller workflow）
    printf '%s\n' "${GH_STUB_WORKFLOW_YAML:-jobs:
  session:
    uses: bannzai/webtunnel/.github/workflows/browser-session.yml@main
    with:
      port: \"8000\"}" | base64
    ;;
  *) exit 1 ;;
esac
EOF

cat > "${STUB_BIN}/curl" <<'EOF'
#!/usr/bin/env bash
# curl のスタブ。CDP の /json/version の応答を模す
[ "${CURL_STUB_OK:-1}" = "1" ] || exit 1
printf '%s\n' '{"Browser": "HeadlessChrome/151"}'
EOF

cat > "${STUB_BIN}/godot-web.sh" <<'EOF'
#!/usr/bin/env bash
# godot-web.sh のスタブ。共通オプションを読み飛ばし、サブコマンドごとに妥当な JSON を返す
set -u

if [ -n "${HELPER_STUB_LOG:-}" ]; then
  printf '%s\n' "$*" >> "$HELPER_STUB_LOG"
fi

# 共通オプション（値付き）を読み飛ばして、最初の非オプション引数をサブコマンドとする
while [ $# -gt 0 ]; do
  case "$1" in
    --cdp|--game-size|--target|--timeout|--canvas|--session) shift 2 ;;
    --*) shift ;;
    *) break ;;
  esac
done
SUB="${1:-}"
if [ $# -gt 0 ]; then shift; fi

if [ -n "${HELPER_STUB_FAIL:-}" ] && [ "${HELPER_STUB_FAIL}" = "$SUB" ]; then
  echo "[stub] ${SUB} を失敗させる (HELPER_STUB_FAIL)" >&2
  exit 1
fi

case "$SUB" in
  status)
    printf '{"href":"%s","started":false,"notice":"","webgl2":true,"viewport":{"width":1280,"height":656},"canvas":null}\n' \
      "${HELPER_STUB_HREF:-about:blank}"
    ;;
  open|fetch-status)
    printf '{"url":"%s","status":%s}\n' "${1:-}" "${HELPER_STUB_HTTP_STATUS:-200}"
    ;;
  wait-started)
    printf '{"href":"http://localhost:8000/index.html","started":true,"notice":"","webgl2":%s,"viewport":{"width":1280,"height":656},"canvas":{"left":0,"top":0,"width":1280,"height":656}}\n' \
      "${HELPER_STUB_WEBGL2:-true}"
    ;;
  shot)
    printf 'x' > "${1:-/dev/null}"
    printf '{"path":"%s","format":"png","bytes":1}\n' "${1:-}"
    ;;
  probe-input)
    printf '%s\n' '{"received":true,"sent":{"key":"Shift","code":"ShiftLeft"},"got":{"key":"Shift","code":"ShiftLeft"}}'
    ;;
  *)
    echo "[stub] 未対応のサブコマンド: ${SUB}" >&2
    exit 1
    ;;
esac
EOF

chmod +x "${STUB_BIN}/gh" "${STUB_BIN}/curl" "${STUB_BIN}/godot-web.sh"

# 実環境の gh / curl を拾わないよう PATH の先頭にスタブを置く（doctor が使う jq は残す）
STUB_PATH="${STUB_BIN}:${JQ_DIR}:/usr/bin:/bin"
LOG_N=0
LOG=""

# 各ケースの前にスタブの設定を戻し、スタブのログを新しいファイルにする
# （前のケースの呼び出し履歴を誤って証拠に使わないため）
reset_stubs() {
  unset GH_STUB_RUNS GH_STUB_FAIL GH_STUB_WORKFLOW_YAML CURL_STUB_OK
  unset HELPER_STUB_FAIL HELPER_STUB_HREF HELPER_STUB_HTTP_STATUS HELPER_STUB_WEBGL2
  LOG_N=$((LOG_N + 1))
  LOG="${TMP}/helper-${LOG_N}.log"
  : > "$LOG"
}

run_doctor() {
  env PATH="$STUB_PATH" \
    GODOT_WEB_HELPER="${STUB_BIN}/godot-web.sh" \
    GODOT_WEB_DOCTOR_DIR="${TMP}/shots" \
    HELPER_STUB_LOG="$LOG" \
    bash "$DOCTOR" "$@" 2>&1
}

CDP_ARG="http://127.0.0.1:9"
URL_ARG="http://localhost:8000/index.html"

# --- 1. すべて OK -----------------------------------------------------------
reset_stubs
export GH_STUB_RUNS="12345 in_progress"
out=$(run_doctor --session dev --cdp "$CDP_ARG" --url "$URL_ARG")
code=$?
assert "すべての段階が通れば exit 0" "0" "$code"
assert_contains "すべて通れば ALL_OK を出力する" "ALL_OK" "$out"
assert_contains "runner を OK にする" "OK   runner" "$out"
assert_contains "cdp を OK にする" "OK   cdp" "$out"
assert_contains "http を OK にする" "OK   http" "$out"
assert_contains "loaded を OK にする" "OK   loaded" "$out"
assert_contains "webgl2 を OK にする" "OK   webgl2" "$out"
assert_contains "shot を OK にする" "OK   shot" "$out"
assert_contains "input を OK にする" "OK   input" "$out"

# --- 2. runner: run が無い --------------------------------------------------
reset_stubs
out=$(run_doctor --session dev --cdp "$CDP_ARG" --url "$URL_ARG")
code=$?
assert "セッションの run が無ければ exit 1" "1" "$code"
assert_contains "run が無い場合は runner を NG にする" "NG   runner" "$out"
assert_contains "run が無い場合の FAILED_STAGE は runner" "FAILED_STAGE=runner" "$out"
assert_contains "run が無いことを理由に書く" "run が無い" "$out"

# --- 3. runner: GitHub API の失敗 -------------------------------------------
reset_stubs
export GH_STUB_FAIL=1
out=$(run_doctor --session dev --cdp "$CDP_ARG" --url "$URL_ARG")
code=$?
assert "GitHub API に到達できなければ exit 1" "1" "$code"
assert_contains "API 失敗の FAILED_STAGE は runner" "FAILED_STAGE=runner" "$out"
assert_contains "API 失敗を run 不在と区別して書く" "GitHub API" "$out"

# --- 4. runner: --session 無しなら SKIP -------------------------------------
reset_stubs
out=$(run_doctor --cdp "$CDP_ARG" --url "$URL_ARG")
code=$?
assert "--cdp 直接指定なら runner で止まらず exit 0" "0" "$code"
assert_contains "--cdp 直接指定は runner を SKIP にする" "SKIP runner" "$out"
assert_contains "--cdp 直接指定でも最後まで通る" "ALL_OK" "$out"

# --- 5. cdp: /json/version が応答しない -------------------------------------
reset_stubs
export CURL_STUB_OK=0
out=$(run_doctor --cdp "$CDP_ARG" --url "$URL_ARG")
code=$?
assert "CDP が応答しなければ exit 1" "1" "$code"
assert_contains "CDP 不通は cdp を NG にする" "NG   cdp" "$out"
assert_contains "CDP 不通の FAILED_STAGE は cdp" "FAILED_STAGE=cdp" "$out"

# --- 6. http: HTTP 404 ------------------------------------------------------
reset_stubs
export HELPER_STUB_HTTP_STATUS=404
out=$(run_doctor --cdp "$CDP_ARG" --url "$URL_ARG")
code=$?
assert "配信が 404 なら exit 1" "1" "$code"
assert_contains "404 は http を NG にする" "NG   http" "$out"
assert_contains "404 の FAILED_STAGE は http" "FAILED_STAGE=http" "$out"
assert_contains "HTTP のコードを理由に書く" "404" "$out"

# --- 7. http: open 自体が失敗 -----------------------------------------------
reset_stubs
export HELPER_STUB_FAIL=open
out=$(run_doctor --cdp "$CDP_ARG" --url "$URL_ARG")
code=$?
assert "open が失敗すれば exit 1" "1" "$code"
assert_contains "open の失敗は http を NG にする" "NG   http" "$out"
assert_contains "open の失敗の FAILED_STAGE は http" "FAILED_STAGE=http" "$out"

# --- 8. http: caller workflow の port から URL を組み立てる -----------------
reset_stubs
export GH_STUB_RUNS="12345 in_progress"
out=$(run_doctor --session dev --cdp "$CDP_ARG")
code=$?
assert "--url も --port も無くても workflow の port で通る" "0" "$code"
assert_contains "workflow の port 8000 から URL を組み立てる" \
  "open http://localhost:8000/index.html" "$(cat "$LOG")"

reset_stubs
export GH_STUB_RUNS="12345 in_progress"
export GH_STUB_WORKFLOW_YAML='jobs:
  session:
    with:
      port: "8123"'
out=$(run_doctor --session dev --cdp "$CDP_ARG")
code=$?
assert "workflow の port が 8123 なら 8123 で組み立てる" "0" "$code"
assert_contains "workflow の port 8123 から URL を組み立てる" \
  "open http://localhost:8123/index.html" "$(cat "$LOG")"

# --- 9. http: URL を決められない --------------------------------------------
reset_stubs
out=$(run_doctor --cdp "$CDP_ARG")
code=$?
assert "URL を決められなければ exit 1" "1" "$code"
assert_contains "URL 不明は http を NG にする" "NG   http" "$out"
assert_contains "URL 不明の FAILED_STAGE は http" "FAILED_STAGE=http" "$out"
assert_contains "--url の指定を促す" "--url" "$out"

# --- 10. http: 既に配信 URL を開いていれば fetch-status で確認する ---------
reset_stubs
export HELPER_STUB_HREF="http://localhost:8000/index.html"
out=$(run_doctor --cdp "$CDP_ARG")
code=$?
log=$(cat "$LOG")
assert "既に配信 URL を開いていれば exit 0" "0" "$code"
assert_contains "配信 URL を開いていれば fetch-status で確認する" \
  "fetch-status http://localhost:8000/index.html" "$log"
assert_not_contains "配信 URL を開いていれば open し直さない" " open " "$log"

# --- 11. loaded: wait-started の失敗 ----------------------------------------
reset_stubs
export HELPER_STUB_FAIL=wait-started
out=$(run_doctor --cdp "$CDP_ARG" --url "$URL_ARG")
code=$?
assert "起動しなければ exit 1" "1" "$code"
assert_contains "起動しない場合は loaded を NG にする" "NG   loaded" "$out"
assert_contains "起動しない場合の FAILED_STAGE は loaded" "FAILED_STAGE=loaded" "$out"

# --- 12. webgl2: 無効 -------------------------------------------------------
reset_stubs
export HELPER_STUB_WEBGL2=false
out=$(run_doctor --cdp "$CDP_ARG" --url "$URL_ARG")
code=$?
assert "WebGL2 が無効なら exit 1" "1" "$code"
assert_contains "WebGL2 無効は webgl2 を NG にする" "NG   webgl2" "$out"
assert_contains "WebGL2 無効の FAILED_STAGE は webgl2" "FAILED_STAGE=webgl2" "$out"
assert_contains "WebGL2 無効は --software-webgl を促す" "--software-webgl" "$out"

# --- 13. shot: 撮影の失敗 ---------------------------------------------------
reset_stubs
export HELPER_STUB_FAIL=shot
out=$(run_doctor --cdp "$CDP_ARG" --url "$URL_ARG")
code=$?
assert "撮影が失敗すれば exit 1" "1" "$code"
assert_contains "撮影の失敗は shot を NG にする" "NG   shot" "$out"
assert_contains "撮影の失敗の FAILED_STAGE は shot" "FAILED_STAGE=shot" "$out"

# --- 14. input: 実入力の失敗 ------------------------------------------------
reset_stubs
export HELPER_STUB_FAIL=probe-input
out=$(run_doctor --cdp "$CDP_ARG" --url "$URL_ARG")
code=$?
assert "実入力が届かなければ exit 1" "1" "$code"
assert_contains "実入力の失敗は input を NG にする" "NG   input" "$out"
assert_contains "実入力の失敗の FAILED_STAGE は input" "FAILED_STAGE=input" "$out"

# --- 15. --skip-input -------------------------------------------------------
reset_stubs
out=$(run_doctor --cdp "$CDP_ARG" --url "$URL_ARG" --skip-input)
code=$?
assert "--skip-input でも exit 0" "0" "$code"
assert_contains "--skip-input は input を SKIP にする" "SKIP input" "$out"
assert_contains "--skip-input でも ALL_OK まで進む" "ALL_OK" "$out"

# --- 16. --deadline 0（期限切れ） -------------------------------------------
reset_stubs
out=$(run_doctor --cdp "$CDP_ARG" --url "$URL_ARG" --deadline 0)
code=$?
assert "期限を使い切っていれば exit 1" "1" "$code"
assert_contains "期限切れを理由に書く" "期限" "$out"

# --- 17. 引数不正 -----------------------------------------------------------
reset_stubs
out=$(run_doctor)
code=$?
assert "--session も --cdp も無ければ exit 2" "2" "$code"

reset_stubs
out=$(run_doctor --cdp "$CDP_ARG" --deadline abc)
code=$?
assert "--deadline が整数でなければ exit 2" "2" "$code"

echo ""
echo "PASS: ${PASS} / FAIL: ${FAIL}"
[ "$FAIL" -eq 0 ]
