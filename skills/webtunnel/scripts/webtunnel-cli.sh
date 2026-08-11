#!/usr/bin/env bash
# local/webtunnel CLI を、skill の設置場所（symlink 経由でも）に依存せず呼び出す薄いラッパー。
# 引数はそのまま CLI へ渡す（サブコマンドと使い方は local/webtunnel の冒頭コメントが SSOT）。
#
# Usage: webtunnel-cli.sh --path      # 解決した CLI の絶対パスを表示して終了
#        webtunnel-cli.sh <args...>   # CLI をそのまま実行
#
# CLI の解決順:
#   1. 環境変数 WEBTUNNEL_CLI（実行可能でなければエラー。明示指定は黙って握りつぶさない）
#   2. 本スクリプトの実体から辿った同一リポジトリの local/webtunnel
#   3. ~/ghq/github.com/bannzai/webtunnel/local/webtunnel
set -euo pipefail

# symlink を辿って本スクリプト自身が置かれた実ディレクトリを返す
resolve_script_dir() {
  local path=$0 target
  while [ -L "$path" ]; do
    target=$(readlink "$path")
    case "$target" in
      /*) path=$target ;;
      *) path=$(dirname "$path")/$target ;;
    esac
  done
  (cd "$(dirname "$path")" && pwd -P)
}

find_cli() {
  if [ -n "${WEBTUNNEL_CLI:-}" ]; then
    if [ ! -x "$WEBTUNNEL_CLI" ]; then
      echo "WEBTUNNEL_CLI が実行可能ではない: ${WEBTUNNEL_CLI}" >&2
      return 1
    fi
    echo "$WEBTUNNEL_CLI"
    return 0
  fi

  local candidate
  # skills/webtunnel/scripts/ から見たリポジトリルートの local/webtunnel
  for candidate in \
    "$(resolve_script_dir)/../../../local/webtunnel" \
    "${HOME}/ghq/github.com/bannzai/webtunnel/local/webtunnel"; do
    if [ -x "$candidate" ]; then
      echo "$(cd "$(dirname "$candidate")" && pwd -P)/$(basename "$candidate")"
      return 0
    fi
  done

  echo "local/webtunnel が見つからない。webtunnel リポジトリを clone するか WEBTUNNEL_CLI にパスを設定する" >&2
  return 1
}

main() {
  local cli
  cli=$(find_cli)

  if [ "${1:-}" = "--path" ]; then
    echo "$cli"
    return 0
  fi

  exec "$cli" "$@"
}

main "$@"
