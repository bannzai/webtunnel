#!/usr/bin/env bash
# Godot の Web エクスポートを webtunnel (CDP) 越しに操作する補助。ゲーム座標のクリック、Control 名でのクリック、
# ms 指定の長押し、宣言的な入力シナリオ、JPEG フォールバック付きの撮影、起動判定を 1 コマンドで行う。
# 実体は同じディレクトリの godot-web-cdp.mjs (Node 22 以上。CDP に直接 WebSocket 接続する。agent-browser と
# 同じ CDP に並行して接続してよい)。
#
# Usage: godot-web.sh [共通オプション] <サブコマンド> [引数]
#
# 共通オプション (サブコマンドの前に置く):
#   --session <session>  webtunnel のセッション名。webtunnel-cli.sh cdp <session> で CDP の URL を引く
#   --cdp <url>          CDP の URL を直接指定 (http://<tailscale IP>:9222。ローカルの headless Chromium も可)
#   --game-size <WxH>    ゲームの表示解像度 (既定 1280x720。環境変数 GODOT_WEB_GAME_SIZE でも指定可)
#   --target <substr>    操作対象ページを URL の部分一致で選ぶ (既定: 最初の page)
#   --timeout <ms>       CDP の各コマンドの応答タイムアウト (既定 30000)
#   --canvas <selector>  canvas のセレクタ (既定 #canvas)
#
# サブコマンド (結果は JSON 1 行で stdout):
#   open <url>                          ページを開いて load を待つ
#   status                              起動判定 (started / notice / webgl2) と viewport・canvas の実寸
#   wait-started [--timeout <ms>]       #status が消える (Godot 起動) まで待つ。#status-notice に理由が入ったら失敗
#   map <game_x> <game_y>               ゲーム座標をブラウザ座標へ写す (canvas の実寸と余白から縮尺とオフセットを計算)
#   click <game_x> <game_y> [--hold <ms>]   ゲーム座標をクリック
#   click-node <Control 名> [--timeout <ms>] Godot 側の診断 autoload (references/godot_web_diag.gd) に Control の
#                                       グローバル矩形を問い合わせ、その中心をクリック。node-rect は問い合わせだけ
#   mouse-move <game_x> <game_y>        マウス移動だけ (保持中のオブジェクトが動くゲーム向け)
#   key <Key> [--hold <ms>]             keydown を送った時刻から数えて hold ms 後に必ず keyup を送る (応答を待たない)
#   keydown <Key> / keyup <Key>         個別に送る (複数キーの同時押し用)
#   shot <path> [--jpeg] [--quality <n>] [--timeout <ms>]  撮影。PNG がタイムアウトしたら JPEG (<path>.jpg) に倒す
#   probe-input [<Key>] [--timeout <ms>] キーを 1 回送ってページ側で受信できたかを返す (doctor の実入力段階)
#   console [--wait <ms>]               指定 ms の間 console を聞いて出す
#   eval <js>                           JavaScript を評価して値を返す
#   seq <シナリオファイル>              1 行 1 操作のシナリオを再生する。形式:
#                                         # コメント
#                                         open http://localhost:8000/index.html
#                                         wait-started 30000
#                                         click 639 430            # ゲーム座標
#                                         key ArrowRight --hold 300
#                                         @2000 key Space          # シナリオ開始から 2000 ms の時刻に実行
#                                         keydown ArrowDown
#                                         wait 80
#                                         keyup ArrowDown
#                                         console-expect "score" 3000
#                                         shot ./tmp/after.png --jpeg
#
# キー名: ArrowLeft / ArrowRight / ArrowUp / ArrowDown / Space / Enter / Escape / Tab / Backspace / Delete / Shift /
#         Control / Alt / Meta / Home / End / PageUp / PageDown / F1..F12 / 英数字 1 文字 / KeyA・Digit1 形式。
#         DOM の key と code の両方を送る (Godot は code を physical_keycode として読む。
#         references/godot-web-export.md「logical key と physical key」)
#
# Exit: 0=成功 / 1=失敗 (到達不能・起動失敗・Control 不在・タイムアウト等) / 2=引数不正
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
IMPL="${SCRIPT_DIR}/godot-web-cdp.mjs"

usage() {
  sed -n '2,52p' "$0" | sed 's/^# \{0,1\}//'
}

main() {
  if [ $# -eq 0 ] || [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    usage
    exit 2
  fi
  command -v node >/dev/null 2>&1 || { echo "node が必要 (Node 22 以上。agent-browser と同じ環境にある)" >&2; exit 1; }
  local major
  major=$(node -p 'process.versions.node.split(".")[0]')
  [ "$major" -ge 22 ] || { echo "Node 22 以上が必要 (global WebSocket)。現在: $(node --version)" >&2; exit 1; }

  # --session <name> は webtunnel-cli.sh cdp で CDP の URL に解決してから実体へ渡す
  local -a args=()
  local session=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --session)
        [ $# -ge 2 ] || { echo "--session にはセッション名が必要" >&2; exit 2; }
        session=$2
        shift 2
        ;;
      *)
        args+=("$1")
        shift
        ;;
    esac
  done
  if [ -n "$session" ]; then
    local cdp_out cdp_url
    cdp_out=$(bash "${SCRIPT_DIR}/webtunnel-cli.sh" cdp "$session") || {
      echo "セッション ${session} の CDP を解決できない (webtunnel-cli.sh cdp ${session})" >&2
      exit 1
    }
    cdp_url=$(printf '%s\n' "$cdp_out" | awk '/^CDP: / {print $2; exit}')
    [ -n "$cdp_url" ] || { echo "webtunnel-cli.sh cdp の出力に CDP: 行が無い: ${cdp_out}" >&2; exit 1; }
    args=(--cdp "$cdp_url" "${args[@]}")
  fi

  exec node "$IMPL" "${args[@]}"
}

main "$@"
