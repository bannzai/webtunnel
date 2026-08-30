#!/bin/bash
# Xvfb 上で Chromium (Google Chrome) を headed 起動し、CDP が 127.0.0.1:$CDP_PORT で応答するまで待つ。
# headless ではなく Xvfb + headed にするのは、ffmpeg の x11grab でセッション全体を録画するため。
# env: CDP_PORT（既定 9222）/ START_URL（既定 about:blank）/ EXTENSION_PATH（空なら拡張を読み込まない）
set -euo pipefail

CDP_PORT="${CDP_PORT:-9222}"
START_URL="${START_URL:-about:blank}"
# caller リポジトリルート相対の拡張ディレクトリ（この step の cwd が workspace ルートのため相対のまま解決できる）
EXTENSION_PATH="${EXTENSION_PATH:-}"
DISPLAY_NUM=":99"
WINDOW_SIZE="1280,800"
SCREEN_SIZE="1280x800x24"
WORK="${RUNNER_TEMP:-$(pwd)/tmp}"
mkdir -p "$WORK"

# 読み込む拡張の検証と ID の導出。Chromium は拡張の読み込みに失敗しても「拡張なし」で起動して
# CDP も応答するため、誤った動作確認にならないよう起動前に落とす（PROJECT.md「Chrome 拡張の読み込み」参照）
EXTENSION_DIR=""
if [ -n "$EXTENSION_PATH" ]; then
  # Chromium は拡張のパスを canonical 化してから ID を導出するため、symlink を解決した実パスに揃える
  EXTENSION_DIR="$(cd "$EXTENSION_PATH" 2>/dev/null && pwd -P)" || {
    echo "extension_path のディレクトリが存在しない: ${EXTENSION_PATH}（cwd: $(pwd)）" >&2
    echo "拡張のビルドが要る場合は setup_command で先にビルドする" >&2
    exit 1
  }
  MANIFEST="$EXTENSION_DIR/manifest.json"
  [ -f "$MANIFEST" ] || {
    echo "extension_path に manifest.json が無い: ${EXTENSION_DIR}" >&2
    echo "パッケージ化されていない拡張のディレクトリ（ビルド済みの dist 等）を指定する" >&2
    exit 1
  }
  command -v jq >/dev/null 2>&1 || { echo "manifest.json の検証に jq が必要" >&2; exit 1; }
  jq -e 'has("manifest_version")' "$MANIFEST" >/dev/null 2>&1 || {
    echo "manifest.json が JSON として不正か manifest_version を持たない: ${MANIFEST}" >&2
    exit 1
  }
  echo "extension: $EXTENSION_DIR"

  # 拡張 ID は、manifest に key があれば公開鍵（DER）の、無ければ拡張ディレクトリの絶対パスの
  # SHA-256 先頭 16 バイトを 0-f → a-p に写した値になる。popup 等の chrome-extension:// URL を
  # 組み立てるために後続 step へ渡す
  EXTENSION_KEY="$(jq -r '.key // empty' "$MANIFEST")"
  if [ -n "$EXTENSION_KEY" ]; then
    EXTENSION_ID="$(printf '%s' "$EXTENSION_KEY" | base64 -d | sha256sum | cut -c1-32 | tr '0-9a-f' 'a-p')"
  else
    EXTENSION_ID="$(printf '%s' "$EXTENSION_DIR" | sha256sum | cut -c1-32 | tr '0-9a-f' 'a-p')"
  fi
  echo "extension id: $EXTENSION_ID"
  [ -z "${GITHUB_ENV:-}" ] || echo "WEBTUNNEL_EXTENSION_ID=$EXTENSION_ID" >> "$GITHUB_ENV"
fi

# ubuntu-latest runner には google-chrome と chromium の両方がプリインストールされている。
# 拡張を読み込む時だけ chromium を優先する（branded な Google Chrome は 137 以降
# --load-extension / --disable-extensions-except を無視する。PROJECT.md「Chrome 拡張の読み込み」参照）
if [ -n "$EXTENSION_DIR" ]; then
  CHROME_BIN="$(command -v chromium-browser || command -v chromium || command -v google-chrome || command -v google-chrome-stable || true)"
else
  CHROME_BIN="$(command -v google-chrome || command -v google-chrome-stable || command -v chromium-browser || command -v chromium || true)"
fi
[ -n "$CHROME_BIN" ] || { echo "Chromium 系バイナリが見つからない" >&2; exit 1; }
CHROME_VERSION="$("$CHROME_BIN" --version)"
echo "chrome: $CHROME_BIN ($CHROME_VERSION)"

EXTENSION_ARGS=()
if [ -n "$EXTENSION_DIR" ]; then
  # Chromium・Chrome for Testing は従来どおり読み込める。branded な Google Chrome 137+ は
  # 引数を無視して「拡張なし」で起動してしまうため、静かに誤検証しないよう失敗させる
  if [[ "$CHROME_VERSION" == "Google Chrome "[0-9]* ]]; then
    chrome_major="$(echo "$CHROME_VERSION" | awk '{print $3}' | cut -d. -f1)"
    [ "${chrome_major:-0}" -lt 137 ] || {
      echo "拡張の読み込みには Chromium ビルドが必要（branded な Google Chrome は 137 以降 --load-extension を無視する）: ${CHROME_VERSION}" >&2
      exit 1
    }
  fi
  EXTENSION_ARGS=(--disable-extensions-except="$EXTENSION_DIR" --load-extension="$EXTENSION_DIR")
fi

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

# ログイン後に出る「パスワードを保存しますか?」バブルはユーザー名を平文で表示し、
# 閉じるまで画面に残るため録画に写り込む（参照: PROJECT.md「ログイン済み状態でのセッション開始」）。
# 抑止する switch は無いのでプロファイルの設定として無効化する
mkdir -p "$WORK/chrome-profile/Default"
cat > "$WORK/chrome-profile/Default/Preferences" <<'JSON'
{"credentials_enable_service":false,"profile":{"password_manager_enabled":false,"password_manager_leak_detection":false}}
JSON

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
  ${EXTENSION_ARGS[@]+"${EXTENSION_ARGS[@]}"} \
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
