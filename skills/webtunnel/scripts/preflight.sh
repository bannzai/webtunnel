#!/usr/bin/env bash
# webtunnel セッションを起動できる状態かを機械的に判定する（読み取りのみ・冪等）。
#
# Usage: preflight.sh <owner/repo>
# Env:   WEBTUNNEL_WORKFLOW  caller workflow のファイル名（既定 browser-session.yml）
#        WEBTUNNEL_CLI       local/webtunnel のパス（webtunnel-cli.sh の解決に使う）
# Exit:  0=READY / 1=NOT_READY / 2=引数不正
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
WORKFLOW="${WEBTUNNEL_WORKFLOW:-browser-session.yml}"

NG_COUNT=0
REASONS=""

ok()   { printf 'OK   %s: %s\n' "$1" "$2"; }
warn() { printf 'WARN %s: %s\n' "$1" "$2"; }
ng() {
  printf 'NG   %s: %s\n' "$1" "$2"
  NG_COUNT=$((NG_COUNT + 1))
  REASONS="${REASONS}  - ${1}: ${3}"$'\n'
}

ts_bin() {
  if command -v tailscale >/dev/null 2>&1; then
    echo "tailscale"
  else
    echo "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  fi
}

if [ $# -ne 1 ]; then
  echo "Usage: preflight.sh <owner/repo>" >&2
  exit 2
fi
REPO=$1
case "$REPO" in
  */*) ;;
  *) echo "owner/repo 形式で指定する: $REPO" >&2; exit 2 ;;
esac

echo "== webtunnel preflight: ${REPO} (workflow: ${WORKFLOW}) =="

cli_path=$(bash "${SCRIPT_DIR}/webtunnel-cli.sh" --path 2>/dev/null || true)
if [ -n "$cli_path" ]; then
  ok "webtunnel-cli" "$cli_path"
else
  ng "webtunnel-cli" "local/webtunnel を解決できない" \
     "webtunnel リポジトリを clone するか WEBTUNNEL_CLI にパスを設定する"
fi

if command -v agent-browser >/dev/null 2>&1; then
  ok "agent-browser" "$(command -v agent-browser)"
else
  ng "agent-browser" "コマンドが無い" "agent-browser をインストールする"
fi

if "$(ts_bin)" status >/dev/null 2>&1; then
  ok "tailnet" "tailscale status が応答する"
else
  ng "tailnet" "tailscale status が応答しない" "Tailscale を起動して tailnet に接続する"
fi

if ! command -v gh >/dev/null 2>&1; then
  ng "gh" "コマンドが無い" "GitHub CLI をインストールして gh auth login する"
else
  ok "gh" "$(command -v gh)"

  visibility=$(gh repo view "$REPO" --json visibility --jq '.visibility' 2>/dev/null || true)
  case "$visibility" in
    PUBLIC|public) ok "visibility" "public" ;;
    PRIVATE|private|INTERNAL|internal)
      warn "visibility" "${visibility}（Linux runner は課金対象だが安価なため private でも使用可）" ;;
    "") ng "visibility" "リポジトリ情報を取得できない" "リポジトリ名と gh の認証を確認する" ;;
    *) ng "visibility" "未知の値: ${visibility}" "gh repo view --json visibility の出力を確認する" ;;
  esac

  # ファイルの存在だけでは workflow_dispatch で起動できるか判定できないため、内容まで確認する
  if workflow_yaml=$(gh api "repos/${REPO}/contents/.github/workflows/${WORKFLOW}" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null); then
    case "$workflow_yaml" in
      *workflow_dispatch*) ok "caller-workflow" ".github/workflows/${WORKFLOW}" ;;
      *) ng "caller-workflow" ".github/workflows/${WORKFLOW} に workflow_dispatch トリガーが無い" \
            "caller workflow に workflow_dispatch を宣言する（PROJECT.md の caller 例を参照）" ;;
    esac
  else
    ng "caller-workflow" ".github/workflows/${WORKFLOW} が無い" \
       "PROJECT.md「各アプリ repo での実行（reusable workflow）」の caller workflow を追加する"
  fi

  # secret の一覧は admin 権限が要る。取得に失敗した場合だけ判定材料から外す（成功なら空でも未登録として扱う）
  if secrets=$(gh secret list -R "$REPO" --json name --jq '.[].name' 2>/dev/null); then
    missing=""
    for name in TS_OIDC_CLIENT_ID TS_OIDC_AUDIENCE; do
      echo "$secrets" | grep -qx "$name" || missing="${missing} ${name}"
    done
    if [ -n "$missing" ]; then
      ng "secrets" "未登録:${missing}" "PROJECT.md「セットアップ手順」に従って trust credential を発行し gh secret set する"
    else
      ok "secrets" "TS_OIDC_CLIENT_ID / TS_OIDC_AUDIENCE"
    fi
  else
    warn "secrets" "TS_OIDC_CLIENT_ID / TS_OIDC_AUDIENCE の登録を確認できない（admin 権限が必要）"
  fi
fi

echo ""
if [ "$NG_COUNT" -eq 0 ]; then
  echo "READY"
  exit 0
fi
echo "NOT_READY (${NG_COUNT} 件)"
printf '%s' "$REASONS"
exit 1
