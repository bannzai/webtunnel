#!/bin/bash
# caller リポジトリのセットアップスクリプト（既定 .webtunnel/setup.sh）があれば実行し、
# ログイン済み状態からセッションを始められるようにする（無ければスキップ）。
# 録画開始・tailnet 参加より前に実行するため、ログイン操作は録画にも tailnet にも露出しない
# （参照: PROJECT.md「ログイン済み状態でのセッション開始」）。
# 認証情報は secret WEBTUNNEL_AUTH_ENV（base64 の KEY=VALUE 列）で受け取り、
# 復号した値を add-mask に登録してからスクリプトの環境変数として渡す。
# セットアップの失敗ではセッションを潰さない（ローカルから手動ログインする余地を残す）。
# env: SETUP_SCRIPT / WEBTUNNEL_AUTH_ENV / CDP_PORT / AGENT_BROWSER_VERSION
set -euo pipefail

SETUP_SCRIPT="${SETUP_SCRIPT:-.webtunnel/setup.sh}"
CDP_PORT="${CDP_PORT:-9222}"
# npm の最新版が予告なく入るのを避けるため版を固定する（uses: の SHA 固定と同じ意図）
AGENT_BROWSER_VERSION="${AGENT_BROWSER_VERSION:-0.34.0}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

warn() {
  echo "::warning::$1"
  {
    echo "## ⚠️ セッション初期化"
    echo ""
    echo "$1"
  } >> "$SUMMARY"
}

# 復号した値を add-mask に登録し、環境変数として export する。
# add-mask はジョブ全体に効くため、以降の step（keepalive の chrome.log 出力等）でも伏字になる。
load_auth_env() {
  local decoded key value
  if ! decoded="$(printf '%s' "$WEBTUNNEL_AUTH_ENV" | base64 -d 2>/dev/null)"; then
    warn "secret \`WEBTUNNEL_AUTH_ENV\` を base64 として復号できなかった。認証情報を渡さずにセットアップを続行する。"
    return 0
  fi

  local -a names=()
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    case "$line" in \#*) continue ;; esac
    key="${line%%=*}"
    value="${line#*=}"
    if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      warn "secret \`WEBTUNNEL_AUTH_ENV\` に \`KEY=VALUE\` 形式でない行がある。その行を無視する。"
      continue
    fi
    # 値を引用符で囲んで書かれていても実値だけを渡す（引用符ごと伏字にすると実値がログに残る）
    if [[ "$value" =~ ^\"(.*)\"$ || "$value" =~ ^\'(.*)\'$ ]]; then
      value="${BASH_REMATCH[1]}"
    fi
    echo "::add-mask::$value"
    export "$key=$value"
    names+=("$key")
  done < <(printf '%s\n' "$decoded")

  if [ ${#names[@]} -gt 0 ]; then
    echo "認証情報を環境変数として渡す: ${names[*]}"
  fi
}

if [ ! -f "$SETUP_SCRIPT" ]; then
  if [ -n "${WEBTUNNEL_AUTH_ENV:-}" ]; then
    warn "secret \`WEBTUNNEL_AUTH_ENV\` が設定されているのに \`${SETUP_SCRIPT}\` が無い。セットアップを行わずセッションを開く。"
  else
    echo "${SETUP_SCRIPT} が無いためスキップ"
  fi
  exit 0
fi

if [ -n "${WEBTUNNEL_AUTH_ENV:-}" ]; then
  load_auth_env
fi

# セットアップスクリプトから CDP でブラウザを操作するための共通ツール。
# 自前の CDP クライアントは作らず、ローカルと同じ agent-browser を使う
# （参照: PROJECT.md「操作レイヤー: agent-browser の CDP 接続」）。
if ! command -v agent-browser >/dev/null 2>&1; then
  # --cdp は起動済みの Chromium に接続するため、Playwright のブラウザバイナリは要らない
  export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
  if npm install -g "agent-browser@${AGENT_BROWSER_VERSION}" --no-fund --no-audit --loglevel=error; then
    echo "agent-browser: $(agent-browser --version)"
  else
    warn "agent-browser のインストールに失敗した。\`${SETUP_SCRIPT}\` を agent-browser 無しで実行する。"
  fi
fi

export WEBTUNNEL_CDP_URL="http://127.0.0.1:${CDP_PORT}"
# runner 上の agent-browser は他の作業と共有されないが、既定セッションを避けて名前を固定する
# （~/.claude/rules/agent-browser-session-naming.md と同じ方針）
export AGENT_BROWSER_SESSION="${AGENT_BROWSER_SESSION:-webtunnel-runner}"

if bash "$SETUP_SCRIPT"; then
  echo "セットアップ成功: ${SETUP_SCRIPT}"
  echo "- セッション初期化（\`${SETUP_SCRIPT}\`）成功" >> "$SUMMARY"
  exit 0
fi

# 失敗すると入力途中のログインフォーム（ユーザー名が見えている）が画面に残り、
# 直後に始まる録画へ写り込む。about:blank に戻してから録画を開始させる
if command -v agent-browser >/dev/null 2>&1; then
  agent-browser --cdp "$WEBTUNNEL_CDP_URL" open about:blank >/dev/null 2>&1 || true
fi
warn "\`${SETUP_SCRIPT}\` の実行に失敗した。ログイン前の状態でセッションを開く（画面は about:blank に戻した）。ログは step「セッションを初期化」を参照。"
exit 0
