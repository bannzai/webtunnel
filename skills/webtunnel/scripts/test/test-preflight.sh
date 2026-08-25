#!/usr/bin/env bash
# preflight.sh の判定（READY / NOT_READY の内訳）と引数検証を、gh / tailscale / agent-browser の
# スタブを PATH の先頭に置いて検証する。
set -uo pipefail

SCRIPT=$(cd "$(dirname "$0")/.." && pwd -P)/preflight.sh
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
    *) assert "$name" "contains:${needle}" "missing" ;;
  esac
}

STUB_BIN="${TMP}/bin"
mkdir -p "$STUB_BIN"

cat > "${STUB_BIN}/gh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  repo)
    [ "${GH_STUB_REPO_FAIL:-0}" = "1" ] && exit 1
    echo "${GH_STUB_VISIBILITY:-PUBLIC}"
    ;;
  api)
    # gh api --jq '.content' と同じく base64 で返す（既定は workflow_dispatch を宣言した caller workflow）
    [ "${GH_STUB_HAS_WORKFLOW:-1}" = "1" ] || exit 1
    printf '%s\n' "${GH_STUB_WORKFLOW_YAML:-on:
  workflow_dispatch:
}" | base64
    ;;
  secret)
    [ "${GH_STUB_SECRETS_READABLE:-1}" = "1" ] || exit 1
    printf '%s\n' ${GH_STUB_SECRETS:-}
    ;;
  *) exit 1 ;;
esac
EOF

cat > "${STUB_BIN}/tailscale" <<'EOF'
#!/usr/bin/env bash
[ "${TS_STUB_OK:-1}" = "1" ]
EOF

cat > "${STUB_BIN}/agent-browser" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "${TMP}/stub-webtunnel" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${STUB_BIN}/gh" "${STUB_BIN}/tailscale" "${STUB_BIN}/agent-browser" "${TMP}/stub-webtunnel"

# 実環境の gh / tailscale / agent-browser を拾わないよう PATH を最小構成にする
run_preflight() {
  env PATH="${STUB_BIN}:/usr/bin:/bin" WEBTUNNEL_CLI="${TMP}/stub-webtunnel" "$@" \
    bash "$SCRIPT" bannzai/webtunnel 2>&1
}

out=$(run_preflight GH_STUB_SECRETS="TS_OIDC_CLIENT_ID TS_OIDC_AUDIENCE")
code=$?
assert "すべて満たす場合は exit 0" "0" "$code"
assert_contains "すべて満たす場合は READY を出力する" "READY" "$out"

out=$(run_preflight GH_STUB_VISIBILITY=PRIVATE GH_STUB_SECRETS="TS_OIDC_CLIENT_ID TS_OIDC_AUDIENCE")
code=$?
assert "private リポジトリでも exit 0" "0" "$code"
assert_contains "private リポジトリは visibility を WARN にする" "WARN visibility" "$out"

out=$(run_preflight GH_STUB_VISIBILITY=INTERNAL GH_STUB_SECRETS="TS_OIDC_CLIENT_ID TS_OIDC_AUDIENCE")
code=$?
assert "internal リポジトリでも exit 0" "0" "$code"
assert_contains "internal リポジトリは visibility を WARN にする" "WARN visibility" "$out"

out=$(run_preflight GH_STUB_VISIBILITY=GARBAGE GH_STUB_SECRETS="TS_OIDC_CLIENT_ID TS_OIDC_AUDIENCE")
code=$?
assert "visibility が未知の値の場合は exit 1" "1" "$code"
assert_contains "未知の visibility を NG にする" "NG   visibility" "$out"

out=$(run_preflight GH_STUB_REPO_FAIL=1 GH_STUB_SECRETS="TS_OIDC_CLIENT_ID TS_OIDC_AUDIENCE")
code=$?
assert "visibility を取得できない場合は exit 1" "1" "$code"
assert_contains "visibility 取得失敗を NG にする" "NG   visibility" "$out"

out=$(run_preflight GH_STUB_HAS_WORKFLOW=0 GH_STUB_SECRETS="TS_OIDC_CLIENT_ID TS_OIDC_AUDIENCE")
code=$?
assert "caller workflow 未整備は exit 1" "1" "$code"
assert_contains "caller workflow 未整備を NG にする" "NG   caller-workflow" "$out"

out=$(run_preflight GH_STUB_WORKFLOW_YAML="on: push" GH_STUB_SECRETS="TS_OIDC_CLIENT_ID TS_OIDC_AUDIENCE")
code=$?
assert "caller workflow に workflow_dispatch が無い場合は exit 1" "1" "$code"
assert_contains "workflow_dispatch が無い caller workflow を NG にする" "NG   caller-workflow" "$out"
assert_contains "workflow_dispatch が無い理由を出力する" "workflow_dispatch" "$out"

out=$(run_preflight TS_STUB_OK=0 GH_STUB_SECRETS="TS_OIDC_CLIENT_ID TS_OIDC_AUDIENCE")
code=$?
assert "tailnet 未接続は exit 1" "1" "$code"
assert_contains "tailnet 未接続を NG にする" "NG   tailnet" "$out"

out=$(run_preflight GH_STUB_SECRETS="TS_OIDC_CLIENT_ID")
code=$?
assert "Secrets が欠けている場合は exit 1" "1" "$code"
assert_contains "欠けている secret 名を出力する" "TS_OIDC_AUDIENCE" "$out"

out=$(run_preflight)
code=$?
assert "secret 一覧が空で取得できた場合は exit 1" "1" "$code"
assert_contains "secret が 1 件も無い場合を NG にする" "NG   secrets" "$out"
assert_contains "両方の secret 名を未登録として出力する" "TS_OIDC_CLIENT_ID TS_OIDC_AUDIENCE" "$out"

out=$(run_preflight GH_STUB_SECRETS_READABLE=0)
code=$?
assert "secret 一覧を取得できない場合は WARN 扱いで exit 0" "0" "$code"
assert_contains "secret 未確認は WARN として出力する" "WARN secrets" "$out"

out=$(env PATH="${STUB_BIN}:/usr/bin:/bin" WEBTUNNEL_CLI="${TMP}/stub-webtunnel" bash "$SCRIPT" 2>&1)
code=$?
assert "引数なしは exit 2" "2" "$code"

out=$(env PATH="${STUB_BIN}:/usr/bin:/bin" WEBTUNNEL_CLI="${TMP}/stub-webtunnel" bash "$SCRIPT" webtunnel 2>&1)
code=$?
assert "owner/repo 形式でない引数は exit 2" "2" "$code"

rm "${STUB_BIN}/agent-browser"
out=$(run_preflight GH_STUB_SECRETS="TS_OIDC_CLIENT_ID TS_OIDC_AUDIENCE")
code=$?
assert "agent-browser が無い場合は exit 1" "1" "$code"
assert_contains "agent-browser の不足を NG にする" "NG   agent-browser" "$out"

echo ""
echo "PASS: ${PASS} / FAIL: ${FAIL}"
[ "$FAIL" -eq 0 ]
