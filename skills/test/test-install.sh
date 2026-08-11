#!/usr/bin/env bash
# install.sh の symlink 設置・冪等性・衝突時の非破壊を、専用の HOME を切って検証する。
set -uo pipefail

SCRIPT=$(cd "$(dirname "$0")/.." && pwd -P)/install.sh
SKILLS_DIR=$(cd "$(dirname "$0")/.." && pwd -P)
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

FAKE_HOME="${TMP}/home"
mkdir -p "${FAKE_HOME}/.claude/skills" "${FAKE_HOME}/.agents/skills"

out=$(SKILL_INSTALL_HOME="$FAKE_HOME" bash "$SCRIPT" webtunnel 2>&1)
code=$?
assert "設置は exit 0" "0" "$code"
assert "Claude Code の skill ディレクトリへ symlink を張る" \
  "${SKILLS_DIR}/webtunnel" "$(readlink "${FAKE_HOME}/.claude/skills/webtunnel")"
assert "Codex CLI の skill ディレクトリへ symlink を張る" \
  "${SKILLS_DIR}/webtunnel" "$(readlink "${FAKE_HOME}/.agents/skills/webtunnel")"
assert "symlink 経由で SKILL.md を読める" \
  "found" "$([ -f "${FAKE_HOME}/.claude/skills/webtunnel/SKILL.md" ] && echo found || echo missing)"
assert "存在しない設置先はスキップする" \
  "skipped" "$(echo "$out" | grep -q 'skip .*\.codex/skills' && echo skipped || echo not-skipped)"

out=$(SKILL_INSTALL_HOME="$FAKE_HOME" bash "$SCRIPT" webtunnel 2>&1)
code=$?
assert "再実行しても exit 0（冪等）" "0" "$code"
assert "再実行時は設置済みと報告する" \
  "reported" "$(echo "$out" | grep -q '設置済み' && echo reported || echo not-reported)"

out=$(SKILL_INSTALL_HOME="$FAKE_HOME" bash "$SCRIPT" 2>&1)
code=$?
assert "skill 名を省略すると skills/ 配下をすべて設置する" "0" "$code"

# 既存の実体がある場合は上書きしない
CONFLICT_HOME="${TMP}/conflict-home"
mkdir -p "${CONFLICT_HOME}/.claude/skills/webtunnel"
echo "既存" > "${CONFLICT_HOME}/.claude/skills/webtunnel/SKILL.md"
out=$(SKILL_INSTALL_HOME="$CONFLICT_HOME" bash "$SCRIPT" webtunnel 2>&1)
code=$?
assert "実体が存在する場合は exit 1" "1" "$code"
assert "衝突した実体を上書きしない" "既存" "$(cat "${CONFLICT_HOME}/.claude/skills/webtunnel/SKILL.md")"

out=$(SKILL_INSTALL_HOME="$FAKE_HOME" bash "$SCRIPT" not-exist-skill 2>&1)
code=$?
assert "存在しない skill 名は exit 1" "1" "$code"

echo ""
echo "PASS: ${PASS} / FAIL: ${FAIL}"
[ "$FAIL" -eq 0 ]
