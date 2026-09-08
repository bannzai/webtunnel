#!/usr/bin/env bash
# Godot の Web エクスポートを webtunnel で開いた時、どの段階まで通っているかを順に判定する (期限付き)。
# 「撮影が数分応答しない」「接続拒否」「起動していない」を 1 つの失敗にまとめず、段階名で切り分ける。
#
# 段階 (この順に判定し、失敗した段階で止まる):
#   runner   caller repo の browser-session workflow に、このセッションの in_progress / queued な run がある
#            (GitHub API の失敗は「run が無い」と区別して報告する)
#   cdp      CDP の /json/version が応答する
#   http     runner 上の配信 HTTP に到達できる (Chromium の中から fetch する。配信サーバは runner の 127.0.0.1 に
#            束縛され tailnet へは露出しないため、ローカルから直接は叩けない。issue の並び「HTTP → CDP」を
#            「CDP → HTTP」に入れ替えているのはこのため)
#   loaded   ページが開いていて Godot 既定シェルの #status が消えている (起動完了)。#status-notice に理由が入れば
#            その文字列を出す
#   webgl2   ページ側から見て WebGL2 が有効 (無効なら up --software-webgl の付け忘れ)
#   shot     CDP の撮影が期限内に終わる (PNG。詰まれば JPEG に倒した結果を出す)
#   input    キーを 1 回送ってページ側で keydown を受信できる (--skip-input で省略。up --wait 直後の自動実行は
#            タイトル画面を進めないよう省略する)
#
# Usage: godot-web-doctor.sh [--session <session>] [--cdp <url>] [--url <index の URL>] [--port <port>]
#                            [--game-size <WxH>] [--deadline <秒>] [--skip-input] [--key <Key>]
#   --session   webtunnel のセッション名。runner 段階と CDP の解決に使う (WEBTUNNEL_REPO / WEBTUNNEL_WORKFLOW を参照)
#   --cdp       CDP の URL を直接指定 (--session が無い場合、runner 段階は SKIP になる)
#   --url       配信 index の URL。省略時は --port から http://localhost:<port>/index.html、--port も無ければ
#               現在のページの URL (about:blank 以外)、それも無ければ caller workflow の port input を gh api で読む
#   --deadline  全体の期限 (既定 180 秒)。各段階のタイムアウトは残り時間に収める
#   --key       input 段階で送るキー (既定 Shift。単独では画面を進めにくい修飾キー)
# Env:   WEBTUNNEL_REPO / WEBTUNNEL_WORKFLOW  runner 段階と port の解決に使う (local/webtunnel と同じ)
#        GODOT_WEB_HELPER                     godot-web.sh のパス (テストでスタブに差し替える用)
#        GODOT_WEB_DOCTOR_DIR                 shot 段階の保存先と helper の stderr の置き場 (既定 ./tmp/godot-web-doctor)
# 期限: --deadline は診断全体の絶対期限。helper の各呼び出しは残り時間で打ち切り、段階を通過しても超過していれば NG にする
# Exit:  0=全段階 OK / 1=いずれかの段階で NG (FAILED_STAGE=<段階名> を出力) / 2=引数不正
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

SCRIPT_DIR=$(resolve_script_dir)
HELPER="${GODOT_WEB_HELPER:-${SCRIPT_DIR}/godot-web.sh}"
REPO="${WEBTUNNEL_REPO:-bannzai/webtunnel}"
WORKFLOW="${WEBTUNNEL_WORKFLOW:-browser-session.yml}"

SESSION=""
CDP=""
URL=""
PORT=""
GAME_SIZE="${GODOT_WEB_GAME_SIZE:-1280x720}"
DEADLINE=180
SKIP_INPUT=0
KEY="Shift"

while [ $# -gt 0 ]; do
  case "$1" in
    --session) SESSION=$2; shift 2 ;;
    --cdp) CDP=$2; shift 2 ;;
    --url) URL=$2; shift 2 ;;
    --port) PORT=$2; shift 2 ;;
    --game-size) GAME_SIZE=$2; shift 2 ;;
    --deadline) DEADLINE=$2; shift 2 ;;
    --skip-input) SKIP_INPUT=1; shift ;;
    --key) KEY=$2; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
    *) echo "不明なオプション: $1" >&2; exit 2 ;;
  esac
done
[ -n "$SESSION" ] || [ -n "$CDP" ] || { echo "--session <session> か --cdp <url> のどちらかが必要" >&2; exit 2; }
case "$DEADLINE" in
  ''|*[!0-9]*) echo "--deadline は秒数 (整数): $DEADLINE" >&2; exit 2 ;;
esac

START=$(date +%s)
END=$((START + DEADLINE))

WORK_DIR="${GODOT_WEB_DOCTOR_DIR:-./tmp/godot-web-doctor}"
mkdir -p "$WORK_DIR"
HELPER_ERR="${WORK_DIR}/helper-stderr.$$"
: > "$HELPER_ERR"

fail() {
  printf 'NG   %s: %s\n' "$1" "$2"
  echo ""
  echo "FAILED_STAGE=$1"
  exit 1
}
# 残り時間 (秒)。0 以下なら期限切れ
remaining() {
  local now
  now=$(date +%s)
  echo $((END - now))
}
# 段階を通過しても、その時点で期限を超えていれば期限切れとして失敗にする (期限は診断全体の絶対期限)
ok() {
  if [ "$(remaining)" -lt 0 ]; then
    fail "$1" "段階自体は通ったが期限 ${DEADLINE} 秒を超過した (--deadline で延ばせる): $2"
  fi
  printf 'OK   %s: %s\n' "$1" "$2"
}
skip() { printf 'SKIP %s: %s\n' "$1" "$2"; }
require_time() {
  local stage=$1
  if [ "$(remaining)" -le 0 ]; then
    fail "$stage" "期限 ${DEADLINE} 秒を使い切った (--deadline で延ばせる)"
  fi
}
# 残り時間に収めた ms のタイムアウト (上限 cap 秒)
stage_timeout_ms() {
  local cap=$1 rem
  rem=$(remaining)
  [ "$rem" -lt "$cap" ] && cap=$rem
  [ "$cap" -lt 1 ] && cap=1
  echo $((cap * 1000))
}

# 外部コマンド (gh / curl / webtunnel-cli.sh / helper) を残り時間で打ち切りながら実行する。応答待ちのまま
# --deadline を過ぎて診断が終わらないことを防ぐ (up --wait の自動診断がここで待ち続けないため)。
# stdout だけを返し、stderr は HELPER_ERR に溜めて失敗時の理由に使う (両方を結合すると JSON が壊れる)
# プロセスとその子孫を止める (親だけ止めても、stdout のパイプを持つ子孫が残ると呼び出し側の
# コマンド置換が終わらず期限を超えて待つため、葉から順に kill する)
kill_tree() {
  local pid=$1 child
  for child in $(pgrep -P "$pid" 2>/dev/null); do
    kill_tree "$child"
  done
  kill "$pid" 2>/dev/null
}
with_deadline() {
  local rem pid killer code
  rem=$(remaining)
  [ "$rem" -ge 1 ] || rem=1
  : > "$HELPER_ERR"
  "$@" 2>>"$HELPER_ERR" &
  pid=$!
  # 監視側の stderr は捨てる (sleep を止めた時の「Terminated」の通知を診断の出力に混ぜない)
  ( sleep "$rem"; kill_tree "$pid" ) >/dev/null 2>&1 &
  killer=$!
  code=0
  wait "$pid" || code=$?
  pkill -P "$killer" 2>/dev/null
  kill "$killer" 2>/dev/null
  wait "$killer" 2>/dev/null
  if [ "$code" -ne 0 ] && [ "$(remaining)" -le 0 ]; then
    echo "期限 ${DEADLINE} 秒を超過したため打ち切った" >>"$HELPER_ERR"
  fi
  return "$code"
}
# helper (godot-web.sh)。--timeout は CDP の 1 要求ごとの制限で、接続・再試行・PNG → JPEG の切り替えを含む
# 全体は制限しないため、with_deadline で残り時間により打ち切る
helper() {
  with_deadline bash "$HELPER" --cdp "$CDP" --game-size "$GAME_SIZE" --timeout "$(stage_timeout_ms 60)" "$@"
}
# 残り時間に収めた秒数 (curl -m 用。上限 cap 秒)
stage_timeout_s() {
  echo $(( $(stage_timeout_ms "$1") / 1000 ))
}
helper_err() { tr '\n' ' ' <"$HELPER_ERR"; }
# helper の stdout が JSON でなければその段階を失敗にする
require_json() {
  local stage=$1 out=$2
  printf '%s' "$out" | jq -e . >/dev/null 2>&1 || fail "$stage" "helper の出力が JSON でない: ${out} $(helper_err)"
}

echo "== godot-web doctor: session=${SESSION:-"(--cdp 直接)"} repo=${REPO} deadline=${DEADLINE}s =="

# --- runner ---------------------------------------------------------------
if [ -n "$SESSION" ]; then
  require_time runner
  if runs=$(with_deadline gh run list -R "$REPO" --workflow "$WORKFLOW" --json databaseId,status,displayTitle \
      --jq ".[] | select(.status == \"in_progress\" or .status == \"queued\") | select(.displayTitle | startswith(\"session=${SESSION} \")) | \"\(.databaseId) \(.status)\""); then
    if [ -n "$runs" ]; then
      ok runner "run $(printf '%s' "$runs" | head -1) (${REPO} / ${WORKFLOW})"
    else
      fail runner "セッション ${SESSION} の in_progress / queued な run が無い (期限切れか down 済み。gh run list -R ${REPO} -w ${WORKFLOW} で履歴を確認し、再度 up する)"
    fi
  else
    fail runner "GitHub API に到達できない (run が無いのではなく取得の失敗。一時エラーなら再実行する): $(helper_err)"
  fi
else
  skip runner "--cdp 直接指定のため run の確認を省略"
fi

# --- cdp ------------------------------------------------------------------
require_time cdp
if [ -z "$CDP" ]; then
  if cdp_out=$(with_deadline bash "${SCRIPT_DIR}/webtunnel-cli.sh" cdp "$SESSION"); then
    CDP=$(printf '%s\n' "$cdp_out" | awk '/^CDP: / {print $2; exit}')
  fi
  [ -n "$CDP" ] || fail cdp "webtunnel-${SESSION} が tailnet に無い (準備中か run の終了。webtunnel-cli.sh status ${SESSION} で確認): $(helper_err)"
fi
if version=$(with_deadline curl -s -m "$(stage_timeout_s 10)" "${CDP}/json/version") && printf '%s' "$version" | grep -q '"Browser"'; then
  ok cdp "${CDP} ($(printf '%s' "$version" | grep -o '"Browser": *"[^"]*"' | head -1))"
else
  fail cdp "${CDP}/json/version が応答しない (run を作り直すと tailscale IP が変わる。webtunnel-cli.sh cdp ${SESSION:-<session>} で引き直す): ${version:-} $(helper_err)"
fi

# --- http -----------------------------------------------------------------
require_time http
status_json=$(helper status) || fail http "CDP には繋がるがページの状態を取得できない: $(helper_err)"
require_json http "$status_json"
current_href=$(printf '%s' "$status_json" | jq -r '.href // ""')
if [ -z "$URL" ]; then
  if [ -n "$PORT" ]; then
    URL="http://localhost:${PORT}/index.html"
  elif [ -n "$current_href" ] && [ "$current_href" != "about:blank" ] && printf '%s' "$current_href" | grep -q '^https\?://'; then
    URL=$current_href
  elif [ -n "$SESSION" ]; then
    # caller workflow の port input を読む (references/godot-web-export.md「配信ポートの確認」と同じ手順)
    if workflow_yaml=$(with_deadline gh api "repos/${REPO}/contents/.github/workflows/${WORKFLOW}" --jq '.content') \
       && PORT=$(printf '%s' "$workflow_yaml" | base64 -d 2>/dev/null | sed -n 's/^[[:space:]]*port:[[:space:]]*"\{0,1\}\([0-9]\{1,5\}\)"\{0,1\}.*/\1/p' | head -1) \
       && [ -n "$PORT" ]; then
      URL="http://localhost:${PORT}/index.html"
    fi
  fi
fi
[ -n "$URL" ] || fail http "配信 URL を決められない。--url か --port を指定する (port は caller workflow ${WORKFLOW} の port input)"
# 対象ページ (query / hash を除き、/ と /index.html を同一視) をすでに開いていれば同一オリジンの fetch で
# (ページ遷移せずゲームの進行を巻き戻さない)、別のページなら open してメインドキュメントの HTTP ステータスで
# 到達を判定する (about:blank からの fetch はオリジンが null で CORS に阻まれるため使わない。オリジンだけの
# 一致で遷移を省くと別のゲームを診断してしまうため、ページ単位で比較する)
normalize_page() {
  printf '%s' "$1" | sed -E 's/[?#].*$//; s#^(https?://[^/]+)/?$#\1/index.html#; s#/$#/index.html#'
}
if [ "$(normalize_page "$current_href")" = "$(normalize_page "$URL")" ]; then
  http_out=$(helper fetch-status "$URL")
else
  http_out=$(helper open "$URL")
fi || fail http "${URL} に runner の Chromium から到達できない ($(helper_err))。ポートは caller workflow ${WORKFLOW} の port input を読む (references/godot-web-export.md「配信ポートの確認」)。配信サーバが起動していなければ run のログ・artifact dev-server-log-<session> を見る"
require_json http "$http_out"
http_code=$(printf '%s' "$http_out" | jq -r '.status')
case "$http_code" in
  2*|3*) ok http "${URL} -> HTTP ${http_code}" ;;
  *) fail http "${URL} は到達できるが HTTP ${http_code} (エクスポート成果物が無い。setup_command のエクスポート失敗なら run のログを見る)" ;;
esac

# --- loaded ---------------------------------------------------------------
require_time loaded
loaded_out=$(helper wait-started --timeout "$(stage_timeout_ms 60)") || fail loaded "$(helper_err)"
require_json loaded "$loaded_out"
ok loaded "#status が消えた (Godot 起動完了): $(printf '%s' "$loaded_out" | jq -c '{href, viewport, canvas}')"

# --- webgl2 ---------------------------------------------------------------
require_time webgl2
if [ "$(printf '%s' "$loaded_out" | jq -r '.webgl2')" = "true" ]; then
  ok webgl2 "ページ側から WebGL2 が有効"
else
  fail webgl2 "ページ側から WebGL2 が無効。up <session> --software-webgl で起動し直す (caller workflow が software_webgl input を宣言していること)"
fi

# --- shot -----------------------------------------------------------------
require_time shot
shot_out=$(helper shot "${WORK_DIR}/doctor-$(date +%H%M%S).png" --timeout "$(stage_timeout_ms 60)") || fail shot "撮影が期限内に終わらない (PNG も JPEG も失敗): $(helper_err)"
require_json shot "$shot_out"
ok shot "$(printf '%s' "$shot_out" | jq -r '"\(.format) \(.bytes) bytes \(.path)" + (if .fallback then " (PNG がタイムアウトし JPEG に倒した)" else "" end)')"

# --- input ----------------------------------------------------------------
if [ "$SKIP_INPUT" -eq 1 ]; then
  skip input "--skip-input"
else
  require_time input
  input_out=$(helper probe-input "$KEY" --timeout "$(stage_timeout_ms 10)") || fail input "キー ${KEY} を送ってもページが keydown を受信しない (canvas のフォーカス・CDP の Input が届いているかを確認): $(helper_err)"
  require_json input "$input_out"
  ok input "$(printf '%s' "$input_out" | jq -c '{sent, got: {key: .got.key, code: .got.code}}')"
fi

echo ""
echo "ALL_OK ($(( $(date +%s) - START )) 秒)"
