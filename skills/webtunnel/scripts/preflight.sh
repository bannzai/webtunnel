#!/usr/bin/env bash
# webtunnel セッションを起動できる状態かを機械的に判定する（読み取りのみ・冪等）。
# trust credential の Subject は Tailscale の API で読めないため、caller repo の OIDC subject 接頭辞と
# 必要な Subject を oidc-subject の項目に表示し、人が突き合わせられるようにする（判定は行わない）。
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

  # Tailscale 側の trust credential の Subject は API で読めないため、Secrets の存在以上の判定はできない。
  # 代わりにこの repo の OIDC subject 接頭辞と形式、必要な Subject を明示して人が突き合わせられるようにする
  # (他の repo 用に発行した credential の値を流用すると、形式が違えば「Tailscale に参加」が 403 になる)
  if sub_prefix=$(gh api "repos/${REPO}/actions/oidc/customization/sub" --jq '.sub_claim_prefix' 2>/dev/null) && [ -n "$sub_prefix" ]; then
    case "$sub_prefix" in
      repo:*@*/*@*) sub_format="immutable ID 形式 (2026-07-15 以降に作成・rename・transfer された repo、または immutable subject に opt-in した repo)" ;;
      repo:*/*)     sub_format="従来形式 (上記に当たらない、2026-07-15 より前から名前が変わっていない repo)" ;;
      *)            sub_format="" ;;
    esac
    if [ -n "$sub_format" ]; then
      ok "oidc-subject" "接頭辞 ${sub_prefix} は ${sub_format}。trust credential の Subject は ${sub_prefix}:* にする (他の repo 用に発行した credential の値を流用しても形式が違えば「Tailscale に参加」が token exchange failed with status 403 になる)"
    else
      warn "oidc-subject" "接頭辞 ${sub_prefix} は未知の形式。trust credential の Subject は ${sub_prefix}:* にする (PROJECT.md「OIDC subject は immutable ID 形式になる」参照)"
    fi
  else
    warn "oidc-subject" "subject 接頭辞を取得できない。gh api repos/${REPO}/actions/oidc/customization/sub --jq '.sub_claim_prefix' で確認する"
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
