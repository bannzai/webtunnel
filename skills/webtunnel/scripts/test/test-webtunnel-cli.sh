#!/usr/bin/env bash
# webtunnel-cli.sh の CLI 解決（環境変数 / リポジトリ内 / symlink 経由）と異常系を検証する。
set -uo pipefail

SCRIPT=$(cd "$(dirname "$0")/.." && pwd -P)/webtunnel-cli.sh
# macOS の /var は /private/var への symlink のため、解決後のパスと比較できるよう実体パスにする
TMP=$(cd "$(mktemp -d)" && pwd -P)
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

# 引数をそのまま出力する CLI のスタブ
STUB="${TMP}/stub-webtunnel"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
echo "called: $*"
EOF
chmod +x "$STUB"

out=$(WEBTUNNEL_CLI="$STUB" bash "$SCRIPT" up dev --wait 2>&1)
assert "WEBTUNNEL_CLI 指定時に引数をそのまま CLI へ渡す" "called: up dev --wait" "$out"

out=$(WEBTUNNEL_CLI="$STUB" bash "$SCRIPT" --path 2>&1)
assert "--path は解決した CLI のパスを表示する" "$STUB" "$out"

out=$(WEBTUNNEL_CLI="${TMP}/not-exist" bash "$SCRIPT" --path 2>&1)
code=$?
assert "WEBTUNNEL_CLI が実行不可なら異常終了する" "1" "$code"
case "$out" in
  *"実行可能ではない"*) assert "WEBTUNNEL_CLI 不正時にエラー理由を出力する" "found" "found" ;;
  *) assert "WEBTUNNEL_CLI 不正時にエラー理由を出力する" "found" "missing: ${out}" ;;
esac

# リポジトリ構成（<repo>/skills/webtunnel/scripts/ と <repo>/local/webtunnel）からの解決
REPO="${TMP}/repo"
mkdir -p "${REPO}/skills/webtunnel/scripts" "${REPO}/local"
cp "$SCRIPT" "${REPO}/skills/webtunnel/scripts/webtunnel-cli.sh"
cat > "${REPO}/local/webtunnel" <<'EOF'
#!/usr/bin/env bash
echo "repo-cli: $*"
EOF
chmod +x "${REPO}/local/webtunnel"

out=$(env -u WEBTUNNEL_CLI bash "${REPO}/skills/webtunnel/scripts/webtunnel-cli.sh" --path 2>&1)
assert "同一リポジトリの local/webtunnel を解決する" "${REPO}/local/webtunnel" "$out"

out=$(env -u WEBTUNNEL_CLI bash "${REPO}/skills/webtunnel/scripts/webtunnel-cli.sh" list 2>&1)
assert "解決した CLI を実行する" "repo-cli: list" "$out"

# symlink 経由（~/.claude/skills/<name> からの設置を想定）でも実体側のリポジトリを解決する
mkdir -p "${TMP}/installed"
ln -s "${REPO}/skills/webtunnel/scripts/webtunnel-cli.sh" "${TMP}/installed/webtunnel-cli.sh"
out=$(env -u WEBTUNNEL_CLI bash "${TMP}/installed/webtunnel-cli.sh" --path 2>&1)
assert "symlink 経由でも実体のリポジトリから解決する" "${REPO}/local/webtunnel" "$out"

echo ""
echo "PASS: ${PASS} / FAIL: ${FAIL}"
[ "$FAIL" -eq 0 ]
