#!/bin/bash
# Xvfb 上で Chromium (Google Chrome) を headed 起動し、CDP が 127.0.0.1:$CDP_PORT で応答するまで待つ。
# headless ではなく Xvfb + headed にするのは、ffmpeg の x11grab でセッション全体を録画するため。
# env: CDP_PORT（既定 9222）/ START_URL（既定 about:blank）
set -euo pipefail

CDP_PORT="${CDP_PORT:-9222}"
START_URL="${START_URL:-about:blank}"
DISPLAY_NUM=":99"
WINDOW_SIZE="1280,800"
SCREEN_SIZE="1280x800x24"
WORK="${RUNNER_TEMP:-$(pwd)/tmp}"
mkdir -p "$WORK"

command -v Xvfb >/dev/null 2>&1 || {
  sudo apt-get update -qq
  sudo apt-get install -y -qq xvfb
}

# 日本語ページの動作確認でテキストが豆腐（□）にならないよう CJK フォントを入れる
if ! fc-list 2>/dev/null | grep -qi "noto sans cjk"; then
  sudo apt-get update -qq
  sudo apt-get install -y -qq fonts-noto-cjk fonts-noto-color-emoji
  fc-cache -f >/dev/null 2>&1 || true
fi

# ubuntu-latest runner には google-chrome がプリインストールされている
CHROME_BIN="$(command -v google-chrome || command -v google-chrome-stable || command -v chromium-browser || true)"
[ -n "$CHROME_BIN" ] || { echo "Chromium 系バイナリが見つからない" >&2; exit 1; }
echo "chrome: $CHROME_BIN ($("$CHROME_BIN" --version))"

nohup Xvfb "$DISPLAY_NUM" -screen 0 "$SCREEN_SIZE" >"$WORK/xvfb.log" 2>&1 &
# Xvfb の起動完了を待つ（xdpyinfo は runner に無いため、X ソケットが生えるのを確認する）
X_SOCKET="/tmp/.X11-unix/X${DISPLAY_NUM#:}"
for _ in $(seq 1 30); do
  [ -S "$X_SOCKET" ] && break
  sleep 1
done
[ -S "$X_SOCKET" ] || { echo "Xvfb が起動しない" >&2; cat "$WORK/xvfb.log" >&2; exit 1; }

# 後続 step（録画・keepalive）へ引き継ぐ
echo "DISPLAY=$DISPLAY_NUM" >> "$GITHUB_ENV"
echo "WEBTUNNEL_WINDOW_SIZE=${WINDOW_SIZE/,/x}" >> "$GITHUB_ENV"

# --no-sandbox: 使い捨て VM 上の動作確認用ブラウザのため sandbox 無効化のリスクを許容し、
#               runner のカーネル設定（unprivileged userns 制限）由来の起動失敗を避ける
# --remote-allow-origins=*: ローカルの DevTools フロントエンド等、Origin 付き WebSocket 接続を許可する
DISPLAY="$DISPLAY_NUM" nohup "$CHROME_BIN" \
  --remote-debugging-port="$CDP_PORT" \
  --user-data-dir="$WORK/chrome-profile" \
  --no-first-run \
  --no-default-browser-check \
  --disable-dev-shm-usage \
  --no-sandbox \
  --remote-allow-origins='*' \
  --window-position=0,0 \
  --window-size="$WINDOW_SIZE" \
  "$START_URL" >"$WORK/chrome.log" 2>&1 &

echo "CDP の応答を待機中..."
for _ in $(seq 1 30); do
  if curl -s -m 3 "http://127.0.0.1:${CDP_PORT}/json/version" >/dev/null; then
    curl -s -m 3 "http://127.0.0.1:${CDP_PORT}/json/version"
    echo ""
    echo "ready: http://127.0.0.1:${CDP_PORT}"
    exit 0
  fi
  sleep 2
done
echo "CDP が応答しない" >&2
tail -n 60 "$WORK/chrome.log" >&2
exit 1
