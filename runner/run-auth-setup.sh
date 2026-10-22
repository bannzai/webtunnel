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

# shellcheck source=runner/load-env-secret.sh
source "$(dirname "$0")/load-env-secret.sh"

# 復号した資格情報（AUTH_ENV_NAMES の変数）を環境に持ったまま残ったプロセスを SIGKILL で止める。
# 対象は agent-browser の daemon や、セットアップスクリプトが setsid で切り離した常駐プロセス等で、
# 止めないと復号済みの資格情報がセッション終了まで /proc/<pid>/environ から読める。
# 判定は /proc/<pid>/environ に「KEY=VALUE」と完全に一致するエントリがあるか。root のプロセスも
# 読めるよう sudo が使えれば sudo で走査する。SIGTERM にしないのは、CDP 接続中の agent-browser が
# 終了処理で Chromium を閉じうるため。走査中に生まれた子を取りこぼさないよう、止める対象が
# 無くなるまで走査を繰り返す（上限 5 回）。
# 対象はセットアップスクリプトの子孫（環境に「WEBTUNNEL_AUTH_SETUP_MARKER=<SETUP_MARKER>」を継承したもの）に
# 限る。WEBTUNNEL_AUTH_ENV に USER=runner のような runner の既存の環境と同じ KEY=VALUE があると、
# Chromium・このシェルや、既存の dev サーバがセットアップ中に生んだ子も一致してしまうため。
# 走査に失敗した時は、止められたか確かめられないため set -e でこのスクリプトごと失敗させる。
# 副作用: 呼び出し後、AUTH_ENV_NAMES の変数をこのシェルから unset する。
stop_credential_holders() {
  [ ${#AUTH_ENV_NAMES[@]} -gt 0 ] || return 0
  [ -d /proc ] || return 0
  local -a unset_args=() scanner=(python3)
  local name stopped
  for name in "${AUTH_ENV_NAMES[@]}"; do unset_args+=(-u "$name"); done
  sudo -n true 2>/dev/null && scanner=(sudo -n python3)
  # 値は argv に出さず stdin に NUL 区切りで渡す。走査プロセス自身は資格情報を env から外して起動する
  stopped="$(for name in "${AUTH_ENV_NAMES[@]}"; do printf '%s=%s\0' "$name" "${!name}"; done |
    env "${unset_args[@]}" "${scanner[@]}" -c '
import os, signal, sys
targets = {e for e in sys.stdin.buffer.read().split(b"\0") if e}
marker = f"WEBTUNNEL_AUTH_SETUP_MARKER={sys.argv[1]}".encode()
me = os.getpid()
for _ in range(5):
    killed = False
    for pid in filter(str.isdigit, os.listdir("/proc")):
        if int(pid) == me:
            continue
        try:
            with open(f"/proc/{pid}/environ", "rb") as f:
                environ = set(f.read().split(b"\0"))
            if marker not in environ or targets.isdisjoint(environ):
                continue
            with open(f"/proc/{pid}/comm") as f:
                comm = f.read().strip()
            os.kill(int(pid), signal.SIGKILL)
        except OSError:
            continue
        killed = True
        print(f"{comm} (pid {pid})")
    if not killed:
        break
' "$SETUP_MARKER")"
  unset "${AUTH_ENV_NAMES[@]}"
  [ -z "$stopped" ] || warn "認証情報を環境変数に持ったまま残ったプロセスを止めた: $(printf '%s' "$stopped" | paste -sd ',' -)。セッション中に残す常駐プロセスは、認証情報の環境変数を外して起動する（\`examples/auth-demo/setup.sh\` 参照）。"
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

AUTH_ENV_NAMES=()
if [ -n "${WEBTUNNEL_AUTH_ENV:-}" ]; then
  load_env_secret WEBTUNNEL_AUTH_ENV "$WEBTUNNEL_AUTH_ENV"
  AUTH_ENV_NAMES=(${LOADED_ENV_NAMES[@]+"${LOADED_ENV_NAMES[@]}"})
fi

export WEBTUNNEL_CDP_URL="http://127.0.0.1:${CDP_PORT}"
# runner 上の agent-browser は他の作業と共有されないが、既定セッションを避けて名前を固定する
# （~/.claude/rules/agent-browser-session-naming.md と同じ方針）
export AGENT_BROWSER_SESSION="${AGENT_BROWSER_SESSION:-webtunnel-runner}"

# セットアップスクリプトに GitHub の永続化ファイルを渡さない（start-dev-server.sh の caller コマンドと同じ扱い。
# セキュリティ境界ではない。PROJECT.md「リポジトリ公開に耐える安全性」の 11 参照）
DECOY_DIR="${RUNNER_TEMP:-$(pwd)/tmp}/auth-setup-github-files"
mkdir -p "$DECOY_DIR"
# stop_credential_holders がセットアップスクリプトの子孫を見分ける印。実行ごとに変え、既存のプロセスと一致させない
SETUP_MARKER="$$-$(date +%s%N)"
caller_env=(env
  WEBTUNNEL_AUTH_SETUP_MARKER="$SETUP_MARKER"
  GITHUB_ENV="$DECOY_DIR/env"
  GITHUB_PATH="$DECOY_DIR/path"
  GITHUB_OUTPUT="$DECOY_DIR/output"
  GITHUB_STATE="$DECOY_DIR/state")

# ハングしたスクリプトを step の timeout-minutes に殺させない。step ごと落ちると
# 録画・tailnet 参加・keepalive まで飛ばされ、「失敗してもセッションは開く」が成立しなくなる。
# 打ち切りはプロセスグループごと行う。ハングした子（復号済みの資格情報を環境に持ち、
# 後から CDP 操作を再開しうる）を残さないため。スクリプトが起動する常駐プロセス
# （dev サーバ等）は、スクリプト側で setsid によりグループから切り離し、認証情報の環境変数を
# 外して起動する（外さなければ直後の stop_credential_holders が止める。examples/auth-demo/setup.sh 参照）
set +e
run_with_timeout "$SETUP_TIMEOUT_SECONDS" "${caller_env[@]}" bash "$SETUP_SCRIPT"
SETUP_STATUS=$?
set -e
stop_credential_holders

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
