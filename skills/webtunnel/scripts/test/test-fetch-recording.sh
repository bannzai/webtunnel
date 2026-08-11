#!/usr/bin/env bash
# fetch-recording.sh の run 特定（セッション名の前方一致・実行中の扱い）とダウンロード引数を、
# gh のスタブを PATH の先頭に置いて検証する。
set -uo pipefail

SCRIPT=$(cd "$(dirname "$0")/.." && pwd -P)/fetch-recording.sh
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
assert_contains() {
  local name=$1 needle=$2 haystack=$3
  case "$haystack" in
    *"$needle"*) assert "$name" "contains" "contains" ;;
    *) assert "$name" "contains:${needle}" "missing (actual: ${haystack})" ;;
  esac
}

command -v jq >/dev/null 2>&1 || { echo "[FAIL] jq が必要"; exit 1; }

STUB_BIN="${TMP}/bin"
mkdir -p "$STUB_BIN"
DOWNLOAD_LOG="${TMP}/download.log"

cat > "${STUB_BIN}/gh" <<'EOF'
#!/usr/bin/env bash
case "$2" in
  list) cat "$GH_STUB_RUNS" ;;
  download)
    echo "$*" >> "$GH_STUB_DOWNLOAD_LOG"
    out_dir=""
    while [ $# -gt 0 ]; do
      [ "$1" = "-D" ] && out_dir=$2
      shift
    done
    mkdir -p "$out_dir"
    : > "${out_dir}/recording.mp4"
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "${STUB_BIN}/gh"

cat > "${TMP}/runs-completed.json" <<'EOF'
[
  {"databaseId": 222, "displayTitle": "session=dev2 duration=60m", "status": "completed"},
  {"databaseId": 111, "displayTitle": "session=dev duration=60m", "status": "completed"}
]
EOF

cat > "${TMP}/runs-in-progress.json" <<'EOF'
[
  {"databaseId": 333, "displayTitle": "session=dev duration=60m", "status": "in_progress"}
]
EOF

cat > "${TMP}/runs-other-session.json" <<'EOF'
[
  {"databaseId": 444, "displayTitle": "session=dev2 duration=60m", "status": "completed"}
]
EOF

run_fetch() {
  env PATH="${STUB_BIN}:/usr/bin:/bin" \
    GH_STUB_RUNS="$1" GH_STUB_DOWNLOAD_LOG="$DOWNLOAD_LOG" \
    bash "$SCRIPT" "${@:2}" 2>&1
}

out=$(run_fetch "${TMP}/runs-completed.json" dev "${TMP}/out")
code=$?
assert "完了済み run があれば exit 0" "0" "$code"
assert_contains "取得した run ID を報告する" "run 111" "$out"
assert_contains "mp4 のパスを出力する" "recording.mp4" "$out"
assert_contains "artifact 名は recording-<session>" "-n recording-dev" "$(cat "$DOWNLOAD_LOG")"
assert_contains "指定した出力ディレクトリへ展開する" "-D ${TMP}/out" "$(cat "$DOWNLOAD_LOG")"

# セッション名は "session=<name> " の前方一致。dev を指定して dev2 の run を拾わないこと
out=$(run_fetch "${TMP}/runs-other-session.json" dev "${TMP}/out2")
code=$?
assert "別セッションの run しか無い場合は exit 1" "1" "$code"
assert_contains "run が無い旨を報告する" "見つからない" "$out"

out=$(run_fetch "${TMP}/runs-in-progress.json" dev "${TMP}/out3")
code=$?
assert "run が実行中なら exit 1" "1" "$code"
assert_contains "実行中は down を促す" "webtunnel down dev" "$out"

out=$(env PATH="${STUB_BIN}:/usr/bin:/bin" GH_STUB_RUNS="${TMP}/runs-completed.json" \
  GH_STUB_DOWNLOAD_LOG="$DOWNLOAD_LOG" bash "$SCRIPT" 2>&1)
code=$?
assert "引数なしは exit 2" "2" "$code"

out=$(env PATH="${STUB_BIN}:/usr/bin:/bin" GH_STUB_RUNS="${TMP}/runs-completed.json" \
  GH_STUB_DOWNLOAD_LOG="$DOWNLOAD_LOG" bash "$SCRIPT" dev "${TMP}/out" extra 2>&1)
code=$?
assert "引数が多い場合は exit 2" "2" "$code"

echo ""
echo "PASS: ${PASS} / FAIL: ${FAIL}"
[ "$FAIL" -eq 0 ]
