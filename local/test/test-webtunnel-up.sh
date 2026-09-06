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

echo ""
echo "PASS: ${PASS} / FAIL: ${FAIL}"
[ "$FAIL" -eq 0 ]
