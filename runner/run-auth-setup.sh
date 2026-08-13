#!/bin/bash
# caller リポジトリのセットアップスクリプト（既定 .webtunnel/setup.sh）があれば実行し、
# ログイン済み状態からセッションを始められるようにする（無ければスキップ）。
# 録画開始・tailnet 参加より前に実行するため、ログイン操作は録画にも tailnet にも露出しない
# （参照: PROJECT.md「ログイン済み状態でのセッション開始」）。
# 認証情報は secret WEBTUNNEL_AUTH_ENV（base64 の KEY=VALUE 列）で受け取り、
# 復号した値を add-mask に登録してからスクリプトの環境変数として渡す。
# セットアップの失敗ではセッションを潰さない（ローカルから手動ログインする余地を残す）。
# 例外は失敗後に画面を about:blank へ戻せたと検証できない場合で、認証情報の露出を防ぐため中断する。
# env: SETUP_SCRIPT / WEBTUNNEL_AUTH_ENV / CDP_PORT / AGENT_BROWSER_VERSION /
#      INSTALL_TIMEOUT_SECONDS / SETUP_TIMEOUT_SECONDS
set -euo pipefail

SETUP_SCRIPT="${SETUP_SCRIPT:-.webtunnel/setup.sh}"
CDP_PORT="${CDP_PORT:-9222}"
# npm の最新版が予告なく入るのを避けるため版を固定する（uses: の SHA 固定と同じ意図）
AGENT_BROWSER_VERSION="${AGENT_BROWSER_VERSION:-0.34.0}"
# step の timeout-minutes より短くして、打ち切りをこのスクリプトの復帰処理側で受ける
INSTALL_TIMEOUT_SECONDS="${INSTALL_TIMEOUT_SECONDS:-180}"
SETUP_TIMEOUT_SECONDS="${SETUP_TIMEOUT_SECONDS:-480}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

warn() {
  echo "::warning::$1"
  {
    echo "## ⚠️ セッション初期化"
    echo ""
    echo "$1"
  } >> "$SUMMARY"
}

# timeout は Linux runner の coreutils に含まれるが、無い環境で全コマンドを失敗させないよう素通しする。
# TERM を無視するプロセスでも打ち切れるよう --kill-after で KILL を予約する（TERM 打ち切りは 124、KILL は 137）
run_with_timeout() {
  local seconds=$1; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout --kill-after 10 "$seconds" "$@"
  else
    "$@"
  fi
}

# セットアップスクリプトの打ち切り用。既定の timeout はプロセスグループごと殺すため、
# スクリプトが起動した常駐プロセス（dev サーバ等）まで道連れになり、
# 「失敗してもセッションは開く」時に手動ログインする相手が消えてしまう。
# --foreground は COMMAND だけに信号を送り、子孫は生かす（GNU timeout の仕様）
run_with_timeout_foreground() {
  local seconds=$1; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout --foreground --kill-after 10 "$seconds" "$@"
  else
    "$@"
  fi
}

# workflow コマンド（`::add-mask::` 等）のデータ部は runner 側で `%25` / `%0D` / `%0A` が
# 元の文字へ復元される。エスケープせずに渡すと、`%25` を含む値では登録されるマスクが実値とずれ、
# 実値がログに出た時に伏字にならない。`%` を先に置換する順序も必須。
# 参照: https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-commands
escape_workflow_command_data() {
  local data=$1
  data="${data//'%'/%25}"
  data="${data//$'\r'/%0D}"
  data="${data//$'\n'/%0A}"
  printf '%s' "$data"
}

# 復号した値を add-mask に登録し、環境変数として export する。
# add-mask はジョブ全体に効くため、以降の step（keepalive の chrome.log 出力等）でも伏字になる。
load_auth_env() {
  local decoded line key value
  if ! decoded="$(printf '%s' "$WEBTUNNEL_AUTH_ENV" | base64 -d 2>/dev/null)"; then
    warn "secret \`WEBTUNNEL_AUTH_ENV\` を base64 として復号できなかった。認証情報を渡さずにセットアップを続行する。"
    return 0
  fi

  local -a names=()
  while IFS= read -r line || [ -n "$line" ]; do
    # Windows で作った KEY=VALUE 列は行末に CR が残り、値の一部として export されてしまう
    line="${line%$'\r'}"
    [ -n "$line" ] || continue
    case "$line" in \#*) continue ;; esac
    # `=` が無い行では ${line%%=*} も ${line#*=} も行全体を返し、KEY=KEY として通ってしまう
    case "$line" in *=*) ;; *)
      warn "secret \`WEBTUNNEL_AUTH_ENV\` に \`=\` を含まない行がある。その行を無視する。"
      continue ;;
    esac
    key="${line%%=*}"
    value="${line#*=}"
    if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      warn "secret \`WEBTUNNEL_AUTH_ENV\` に \`KEY=VALUE\` 形式でない行がある。その行を無視する。"
      continue
    fi
    # GITHUB_ENV / PATH 等の制御用変数を secret の値で上書きされると、このスクリプトや
    # 後続コマンドの挙動（GitHub の永続化ファイルの行き先・コマンド解決）を乗っ取れてしまう
    case "$key" in
      GITHUB_*|RUNNER_*|ACTIONS_*|CI|PATH|HOME|SHELL|BASH_ENV|ENV|LD_*)
        warn "secret \`WEBTUNNEL_AUTH_ENV\` の \`${key}\` は GitHub Actions・シェルの制御用変数名のため無視する。"
        continue ;;
    esac
    # 最初の `=` 以降は引用符も含めて生の値として扱う（引用符・エスケープの構文は提供しない。
    # 「気を利かせて」剥がすと、引用符で始まり引用符で終わる正規のパスワードを壊す）
    # 空値の add-mask は runner が警告を出すだけなので登録しない（export はする）
    if [ -n "$value" ]; then
      echo "::add-mask::$(escape_workflow_command_data "$value")"
    fi
    # UID 等シェルの readonly 変数名への代入は if 条件の中でもシェルごと中断させる致命エラーになる。
    # サブシェルで代入可否を先に確かめ、不可なら警告して続行する（step ごと死なせない）
    if ( export "$key=$value" ) 2>/dev/null; then
      export "$key=$value"
      names+=("$key")
    else
      warn "secret \`WEBTUNNEL_AUTH_ENV\` の \`${key}\` は export できない変数名（シェルの readonly 等）のため無視する。"
    fi
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

# セットアップスクリプトから CDP でブラウザを操作するための共通ツール。
# 自前の CDP クライアントは作らず、ローカルと同じ agent-browser を使う
# （参照: PROJECT.md「操作レイヤー: agent-browser の CDP 接続」）。
# 認証情報の export より前に行う。npm の lifecycle スクリプト（依存ツリー含む）は
# サードパーティのコードであり、caller のセットアップスクリプト専用の資格情報を見せない
if ! command -v agent-browser >/dev/null 2>&1; then
  # --cdp は起動済みの Chromium に接続するため、Playwright のブラウザバイナリは要らない
  export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
  # 復号前の secret も npm の lifecycle スクリプト（サードパーティコード）に見せない
  if run_with_timeout "$INSTALL_TIMEOUT_SECONDS" env -u WEBTUNNEL_AUTH_ENV npm install -g "agent-browser@${AGENT_BROWSER_VERSION}" --no-fund --no-audit --loglevel=error; then
    echo "agent-browser: $(agent-browser --version)"
  else
    warn "agent-browser のインストールに失敗した（${INSTALL_TIMEOUT_SECONDS} 秒でタイムアウトした可能性あり）。\`${SETUP_SCRIPT}\` を agent-browser 無しで実行する。"
  fi
fi

if [ -n "${WEBTUNNEL_AUTH_ENV:-}" ]; then
  load_auth_env
fi

export WEBTUNNEL_CDP_URL="http://127.0.0.1:${CDP_PORT}"
# runner 上の agent-browser は他の作業と共有されないが、既定セッションを避けて名前を固定する
# （~/.claude/rules/agent-browser-session-naming.md と同じ方針）
export AGENT_BROWSER_SESSION="${AGENT_BROWSER_SESSION:-webtunnel-runner}"

# セットアップスクリプトに、この job が持つ OIDC トークン発行能力（id-token: write）と
# GitHub の永続化ファイルを渡さない（start-dev-server.sh の caller コマンドと同じハードニング。
# PROJECT.md「リポジトリ公開に耐える安全性」参照）
DECOY_DIR="${RUNNER_TEMP:-$(pwd)/tmp}/auth-setup-github-files"
mkdir -p "$DECOY_DIR"
caller_env=(env
  -u ACTIONS_ID_TOKEN_REQUEST_URL -u ACTIONS_ID_TOKEN_REQUEST_TOKEN
  GITHUB_ENV="$DECOY_DIR/env"
  GITHUB_PATH="$DECOY_DIR/path"
  GITHUB_OUTPUT="$DECOY_DIR/output"
  GITHUB_STATE="$DECOY_DIR/state")

# ハングしたスクリプトを step の timeout-minutes に殺させない。step ごと落ちると
# 録画・tailnet 参加・keepalive まで飛ばされ、「失敗してもセッションは開く」が成立しなくなる
set +e
run_with_timeout_foreground "$SETUP_TIMEOUT_SECONDS" "${caller_env[@]}" bash "$SETUP_SCRIPT"
SETUP_STATUS=$?
set -e

if [ "$SETUP_STATUS" -eq 0 ]; then
  echo "セットアップ成功: ${SETUP_SCRIPT}"
  echo "- セッション初期化（\`${SETUP_SCRIPT}\`）成功" >> "$SUMMARY"
  exit 0
fi

# 失敗すると入力途中のログインフォーム（ユーザー名が見えている）が画面に残り、
# 直後に始まる録画へ写り込む。agent-browser の不調がセットアップ失敗の原因でも動くよう
# CDP を直接叩いて空タブを開き、それ以外の page タブを全て閉じてから残数で検証する
blank_browser() {
  local base="http://127.0.0.1:${CDP_PORT}"
  # Chrome 111+ の /json/new は PUT 必須
  curl -s -m 5 -X PUT "${base}/json/new?about:blank" >/dev/null || return 1
  local ids id
  ids="$(curl -s -m 5 "${base}/json/list" | jq -r '.[] | select(.type == "page" and .url != "about:blank") | .id')" || return 1
  for id in $ids; do
    curl -s -m 5 "${base}/json/close/${id}" >/dev/null || true
  done
  local remaining
  remaining="$(curl -s -m 5 "${base}/json/list" | jq -r '[.[] | select(.type == "page" and .url != "about:blank")] | length')" || return 1
  [ "$remaining" = "0" ]
}

# 画面に認証情報が残っていない保証が取れない場合は、録画だけでなく preview・CDP の
# tailnet 公開も同じ画面を晒すため、セッション自体を開かず中断する（step を失敗させて後続を止める）
if ! blank_browser; then
  warn "\`${SETUP_SCRIPT}\` の失敗後に画面を初期化できなかった。入力途中の認証情報が録画・preview・CDP に露出しうるため、セッションを開かず中断する。"
  exit 1
fi
if [ "$SETUP_STATUS" -eq 124 ] || [ "$SETUP_STATUS" -eq 137 ]; then
  warn "\`${SETUP_SCRIPT}\` が ${SETUP_TIMEOUT_SECONDS} 秒で終わらなかったため打ち切った（exit ${SETUP_STATUS}）。ログイン前の状態でセッションを開く（画面は about:blank に戻した）。"
else
  warn "\`${SETUP_SCRIPT}\` の実行に失敗した（exit ${SETUP_STATUS}）。ログイン前の状態でセッションを開く（画面は about:blank に戻した）。ログは step「セッションを初期化」を参照。"
fi
exit 0
