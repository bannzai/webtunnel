#!/usr/bin/env bash
# 本リポジトリの skills/<name>/ を、AI エージェントが読むグローバル skill ディレクトリへ symlink で設置する。
# skill の実体はこのリポジトリに置いたまま、Claude Code / Codex CLI から使えるようにする。
#
# Usage: install.sh [skill 名 ...]   # 省略時は skills/ 配下のすべて
# Env:   SKILL_INSTALL_HOME  設置先の HOME（既定 $HOME）
# Exit:  0=成功 / 1=失敗（既存の別実体との衝突・skill が存在しない）
#
# 冪等: 既に同じ実体を指す symlink がある場合は何もしない。
#       別の実体（実ディレクトリや別 skill への symlink）がある場合は上書きせずエラーにする。
set -euo pipefail

SKILLS_DIR=$(cd "$(dirname "$0")" && pwd -P)
TARGET_HOME="${SKILL_INSTALL_HOME:-$HOME}"
# Claude Code は ~/.claude/skills、Codex CLI は ~/.agents/skills を読む（~/.codex/skills は Codex の従来パス）
ROOTS=".claude/skills .agents/skills .codex/skills"

ERRORS=0

install_one() {
  local name=$1
  local src="${SKILLS_DIR}/${name}"

  if [ ! -f "${src}/SKILL.md" ]; then
    echo "skill が見つからない: ${src}/SKILL.md" >&2
    ERRORS=$((ERRORS + 1))
    return
  fi

  local root dir link
  for root in $ROOTS; do
    dir="${TARGET_HOME}/${root}"
    if [ ! -d "$dir" ]; then
      echo "skip ${dir}（ディレクトリが無い）"
      continue
    fi
    link="${dir}/${name}"

    if [ -L "$link" ]; then
      if [ -d "$link" ] && [ "$(cd "$link" && pwd -P)" = "$src" ]; then
        echo "ok   ${link}（設置済み）"
      else
        echo "衝突: ${link} は別の実体を指す symlink（$(readlink "$link")）" >&2
        ERRORS=$((ERRORS + 1))
      fi
      continue
    fi
    if [ -e "$link" ]; then
      echo "衝突: ${link} に実体が存在する" >&2
      ERRORS=$((ERRORS + 1))
      continue
    fi

    ln -s "$src" "$link"
    echo "link ${link} -> ${src}"
  done
}

main() {
  local names="$*"
  if [ -z "$names" ]; then
    local d
    for d in "${SKILLS_DIR}"/*/; do
      [ -f "${d}SKILL.md" ] || continue
      names="${names} $(basename "$d")"
    done
  fi

  if [ -z "$names" ]; then
    echo "設置対象の skill が無い: ${SKILLS_DIR}" >&2
    exit 1
  fi

  local name
  for name in $names; do
    install_one "$name"
  done

  [ "$ERRORS" -eq 0 ]
}

main "$@"
