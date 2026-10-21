#!/usr/bin/env bash
# local/webtunnel が接続先ノードを、tag:ci と起動中の run id の両方で確かめて選ぶことを検証する。
# gh と tailscale は PATH 上のスタブに差し替え、cdp が出力する接続先で観測する。
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

# tailscale スタブ: status --json の出力を TS_STUB_JSON で与える
cat > "$TMP/tailscale" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${TS_STUB_JSON}"
EOF
# gh スタブ: run list は GH_STUB_RUN_IDS（空白区切り）を 1 行ずつ返す。GH_STUB_RUN_LIST_FAIL=1 なら失敗する
cat > "$TMP/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "run list")
    [ "${GH_STUB_RUN_LIST_FAIL:-0}" = "1" ] && exit 1
    for id in ${GH_STUB_RUN_IDS:-}; do echo "$id"; done
    ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$TMP/tailscale" "$TMP/gh"

# peer <HostName> <IPv4> <Tags の JSON 配列> [Online]
peer() {
  printf '"%s-%s":{"HostName":"%s","Tags":%s,"Online":%s,"TailscaleIPs":["%s","fd7a:115c:a1e0::%s"]}' \
    "$1" "$2" "$1" "$3" "${4:-true}" "$2" "${2##*.}"
}
# tailnet の Peer 一覧（引数は peer の出力）
peers() {
  local IFS=,
  printf '{"Peer":{%s}}' "$*"
}

# cdp を実行し、接続先の IP を返す（解決できなければ none）
resolved_ip() {
  local json=$1; shift
  local out
  out=$(TS_STUB_JSON="$json" PATH="$TMP:$PATH" "$@" bash "$CLI" cdp dev 2>/dev/null) || { echo none; return; }
  printf '%s\n' "$out" | sed -n 's|^CDP: http://\([^:]*\):9222$|\1|p'
}

ours=$(peer webtunnel-dev-123 100.64.0.1 '["tag:ci"]')
untagged_same_name=$(peer webtunnel-dev-123 100.64.0.9 'null')
other_tag=$(peer webtunnel-dev-123 100.64.0.7 '["tag:dev"]')
other_run=$(peer webtunnel-dev-999 100.64.0.8 '["tag:ci"]')
legacy_name=$(peer webtunnel-dev 100.64.0.6 '["tag:ci"]')
other_session=$(peer webtunnel-dev-x-123 100.64.0.5 '["tag:ci"]')

assert "tag:ci が付いた自分の run のノードを採用する" "100.64.0.1" \
  "$(resolved_ip "$(peers "$ours")" env GH_STUB_RUN_IDS=123)"
assert "tag:ci の無いノードは、名前が一致しても採用しない" "none" \
  "$(resolved_ip "$(peers "$untagged_same_name")" env GH_STUB_RUN_IDS=123)"
assert "tag:ci 以外のタグのノードは採用しない" "none" \
  "$(resolved_ip "$(peers "$other_tag")" env GH_STUB_RUN_IDS=123)"
assert "run id が起動中の run と一致しないノードは採用しない" "none" \
  "$(resolved_ip "$(peers "$other_run")" env GH_STUB_RUN_IDS=123)"
assert "run id を含まないホスト名 webtunnel-<session> のノードは採用しない" "none" \
  "$(resolved_ip "$(peers "$legacy_name")" env GH_STUB_RUN_IDS=123)"
assert "別セッション名（webtunnel-dev-x-<run id>）のノードは採用しない" "none" \
  "$(resolved_ip "$(peers "$other_session")" env GH_STUB_RUN_IDS=123)"

assert "同名のノードが 2 つある時は、tag:ci の付いた自分の run のノードを選ぶ" "100.64.0.1" \
  "$(resolved_ip "$(peers "$untagged_same_name" "$ours")" env GH_STUB_RUN_IDS=123)"
assert "同じセッションの tag:ci ノードが 2 つある時は、自分の run id のノードを選ぶ" "100.64.0.1" \
  "$(resolved_ip "$(peers "$other_run" "$legacy_name" "$ours")" env GH_STUB_RUN_IDS=123)"
assert "起動中の run が複数ある時は、そのいずれかのノードを採用する" "100.64.0.1" \
  "$(resolved_ip "$(peers "$ours")" env GH_STUB_RUN_IDS="456 123")"
assert "同じ run のノードが online と offline で 2 つある時は online を選ぶ" "100.64.0.1" \
  "$(resolved_ip "$(peers "$(peer webtunnel-dev-123 100.64.0.4 '["tag:ci"]' false)" "$ours")" env GH_STUB_RUN_IDS=123)"

assert "起動中の run が無い時は採用しない" "none" \
  "$(resolved_ip "$(peers "$ours")" env GH_STUB_RUN_IDS=)"
assert "run 一覧を取得できない時は名前だけで採用しない" "none" \
  "$(resolved_ip "$(peers "$ours")" env GH_STUB_RUN_IDS=123 GH_STUB_RUN_LIST_FAIL=1)"

out=$(TS_STUB_JSON="$(peers "$untagged_same_name" "$other_run" "$ours")" PATH="$TMP:$PATH" bash "$CLI" list 2>/dev/null)
assert "list は tag:ci の webtunnel ノードだけを表示する" "webtunnel-dev-123  100.64.0.1|webtunnel-dev-999  100.64.0.8" \
  "$(printf '%s\n' "$out" | grep '^webtunnel-' | paste -sd '|' -)"

echo ""
echo "PASS: ${PASS} / FAIL: ${FAIL}"
[ "$FAIL" -eq 0 ]
