#!/usr/bin/env bash
# godot-web.sh（実体は godot-web-cdp.mjs）を、ローカルの headless Chromium と Godot 既定シェルを模した
# 雛形ページ（fixtures/godot-shell-mock）で実際に操作して検証する。
#
# 検証するのは、座標変換（レターボックスの逆算）・Control 名でのクリック・押下時間・キーの logical/physical・
# 撮影・シナリオ再生・失敗時の切り分け（到達不能 / 起動失敗 / canvas 無し）。
#
# 前提: Node 22 以上と Chromium（headless）。どちらも無ければ UNAVAILABLE を出して exit 2 にする（黙って PASS にしない）。
#   GODOT_WEB_TEST_CHROMIUM  Chromium の実行ファイルを明示指定する
#
# 座標の期待値（viewport 1280x656 / map (639,430) -> (639,392)）は Playwright の chrome-headless-shell と
# runner の Chromium の実測に合わせてある。macOS の通常の Chrome（Google Chrome for Testing）を
# --headless=new で使うと viewport が 1280x513 になり、Page.navigate も応答しないため通らない。
# 探索順で chrome-headless-shell を先に選ぶのはこのため。
set -uo pipefail

SCRIPT=$(cd "$(dirname "$0")/.." && pwd -P)/godot-web.sh
FIXTURE=$(cd "$(dirname "$0")" && pwd -P)/fixtures/godot-shell-mock

# --- 前提の確認 -------------------------------------------------------------
unavailable() {
  echo "UNAVAILABLE: $1"
  exit 2
}

command -v node >/dev/null 2>&1 || unavailable "node が無い"
NODE_MAJOR=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null)
case "$NODE_MAJOR" in
  ''|*[!0-9]*) unavailable "node のバージョンを取得できない" ;;
esac
[ "$NODE_MAJOR" -ge 22 ] || unavailable "Node 22 以上が必要 (global WebSocket)。現在: $(node --version)"
command -v jq >/dev/null 2>&1 || unavailable "jq が無い (JSON の検証に使う)"
command -v python3 >/dev/null 2>&1 || unavailable "python3 が無い (fixture の配信に使う)"

# 引数のうち実行可能なものから、パス中のバージョン番号 (…-<数字>/…) が最大のものを 1 つ返す
pick_latest() {
  local path ver best="" best_ver=-1
  for path in "$@"; do
    [ -x "$path" ] || continue
    ver=$(printf '%s\n' "$path" | sed -n 's/.*-\([0-9][0-9]*\)\/.*/\1/p' | head -1)
    case "$ver" in
      ''|*[!0-9]*) ver=0 ;;
    esac
    if [ "$ver" -gt "$best_ver" ]; then
      best_ver=$ver
      best=$path
    fi
  done
  printf '%s' "$best"
}

CHROME="${GODOT_WEB_TEST_CHROMIUM:-}"
if [ -z "$CHROME" ]; then
  # Playwright が置く Chromium（macOS / Linux の両方）を新しいバージョンから探す
  CHROME=$(pick_latest \
    "${HOME}"/Library/Caches/ms-playwright/chromium_headless_shell-*/chrome-headless-shell-mac-arm64/chrome-headless-shell \
    "${HOME}"/Library/Caches/ms-playwright/chromium-*/chrome-mac-arm64/*/Contents/MacOS/* \
    "${HOME}"/Library/Caches/ms-playwright/chromium_headless_shell-*/chrome-headless-shell-linux64/chrome-headless-shell \
    "${HOME}"/Library/Caches/ms-playwright/chromium-*/chrome-linux/chrome)
fi
if [ -z "$CHROME" ]; then
  CHROME=$(command -v chromium chromium-browser google-chrome google-chrome-stable 2>/dev/null | head -1)
fi
if [ -z "$CHROME" ] && [ -x "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" ]; then
  CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
fi
[ -n "$CHROME" ] || unavailable "Chromium が無い (GODOT_WEB_TEST_CHROMIUM で指定する)"
# GODOT_WEB_TEST_CHROMIUM に実行できないパスが入っていた場合も、起動失敗ではなく UNAVAILABLE にする
[ -x "$CHROME" ] || unavailable "Chromium を実行できない: ${CHROME} (GODOT_WEB_TEST_CHROMIUM で指定する)"

# --- 後片付け ---------------------------------------------------------------
TMP=$(mktemp -d)
HTTP_PID=""
CHROME_PID=""
cleanup() {
  [ -n "$CHROME_PID" ] && kill "$CHROME_PID" 2>/dev/null
  [ -n "$HTTP_PID" ] && kill "$HTTP_PID" 2>/dev/null
  # Chromium がプロファイルへ書き込み中だと rm -rf が「Directory not empty」になるため終了を待つ
  [ -n "$CHROME_PID" ] && wait "$CHROME_PID" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

# --- assert -----------------------------------------------------------------
PASS=0
FAIL=0
assert() {
  local name=$1 expected=$2 actual=$3
  if [ "$expected" = "$actual" ]; then
    echo "[PASS] ${name}"
    PASS=$((PASS + 1))
  else
    echo "[FAIL] ${name} (expected: ${expected} / actual: ${actual})"
    FAIL=$((FAIL + 1))
  fi
}
assert_contains() {
  local name=$1 needle=$2 haystack=$3
  case "$haystack" in
    *"$needle"*) assert "$name" "contains" "contains" ;;
    *) assert "$name" "contains:${needle}" "missing (actual: ${haystack})" ;;
  esac
}
# 整数 actual が min 以上 max 以下か
assert_between() {
  local name=$1 min=$2 max=$3 actual=$4
  case "$actual" in
    ''|*[!0-9-]*) assert "$name" "${min}..${max}" "数値ではない: ${actual}"; return ;;
  esac
  if [ "$actual" -ge "$min" ] && [ "$actual" -le "$max" ]; then
    assert "${name} (実測 ${actual})" "in-range" "in-range"
  else
    assert "$name" "${min}..${max}" "$actual"
  fi
}

# --- fixture の配信 ---------------------------------------------------------
# -u が無いとポートを出す行がバッファされて読めない
python3 -u -m http.server 0 --bind 127.0.0.1 --directory "$FIXTURE" > "${TMP}/http.log" 2>&1 &
HTTP_PID=$!
HTTP_PORT=""
for _ in $(seq 1 50); do
  HTTP_PORT=$(sed -n 's/.*port \([0-9][0-9]*\).*/\1/p' "${TMP}/http.log" | head -1)
  [ -n "$HTTP_PORT" ] && break
  sleep 0.2
done
if [ -z "$HTTP_PORT" ]; then
  echo "[FAIL] fixture の配信ポートを 10 秒以内に読めない: $(cat "${TMP}/http.log")"
  exit 1
fi
BASE="http://127.0.0.1:${HTTP_PORT}"

# --- Chromium の起動（1 プロセスを全項目で使い回す） -------------------------
# --use-mock-keychain: 使い捨てプロファイルの起動ごとに macOS のログインキーチェーンへ Cookie 暗号化キーを
# 作ろうとして「Chromium Safe Storage」の許可ダイアログが出るのを防ぐ（キーチェーンに触らない）
mkdir -p "${TMP}/profile"
"$CHROME" --headless=new --remote-debugging-port=0 --user-data-dir="${TMP}/profile" \
  --window-size=1280,656 --no-first-run --disable-gpu --use-mock-keychain about:blank > "${TMP}/chrome.log" 2>&1 &
CHROME_PID=$!
CDP_PORT=""
for _ in $(seq 1 75); do
  if [ -s "${TMP}/profile/DevToolsActivePort" ]; then
    CDP_PORT=$(head -1 "${TMP}/profile/DevToolsActivePort")
    [ -n "$CDP_PORT" ] && break
  fi
  sleep 0.2
done
if [ -z "$CDP_PORT" ]; then
  echo "[FAIL] Chromium の DevToolsActivePort を 15 秒以内に読めない: $(cat "${TMP}/chrome.log")"
  exit 1
fi
CDP="http://127.0.0.1:${CDP_PORT}"
echo "chromium: ${CHROME}"
echo "cdp: ${CDP} / fixture: ${BASE}"
echo ""

gw() { bash "$SCRIPT" --cdp "$CDP" --timeout 10000 "$@"; }
# window.__mock の配列長を返す（差分だけを見るための目印）
mock_len() { gw eval "window.__mock.${1}.length" 2>/dev/null | jq -r '.value'; }
# window.__mock の配列を n 番目以降だけ JSON で返す
mock_slice() { gw eval "window.__mock.${1}.slice(${2})" 2>/dev/null; }

# --- 1. open ----------------------------------------------------------------
out=$(gw open "${BASE}/index.html" 2>&1)
code=$?
assert "open は exit 0" "0" "$code"
assert "open のメインドキュメントの HTTP ステータスは 200" "200" "$(printf '%s' "$out" | jq -r '.status')"

# --- 2. wait-started と幾何 -------------------------------------------------
# 幾何が違うとクリックの失敗と区別できないため、座標の検証より先に確認する
out=$(gw wait-started 2>&1)
code=$?
assert "wait-started は exit 0" "0" "$code"
assert "wait-started の started は true" "true" "$(printf '%s' "$out" | jq -r '.started')"
assert "viewport は 1280x656" "1280x656" \
  "$(printf '%s' "$out" | jq -r '"\(.viewport.width)x\(.viewport.height)"')"
assert "canvas は 1280x656" "1280x656" \
  "$(printf '%s' "$out" | jq -r '"\(.canvas.width)x\(.canvas.height)"')"

# --- 3. map -----------------------------------------------------------------
# 1280x720 のゲームを 1280x656 の canvas に表示した時のレターボックス変換
# （references/godot-web-export.md の実測値 (639,430) -> (639,392) と一致すること）
out=$(gw map 639 430 2>&1)
code=$?
assert "map は exit 0" "0" "$code"
assert "map 639 430 のブラウザ座標 x は 639" "639" "$(printf '%s' "$out" | jq -r '.x')"
assert "map 639 430 のブラウザ座標 y は 392" "392" "$(printf '%s' "$out" | jq -r '.y')"

# --- 4. click（ゲーム座標 → ブラウザ座標 → ページ側でゲーム座標へ逆変換） ---
before=$(mock_len hits)
out=$(gw click 639 430 2>&1)
code=$?
assert "click は exit 0" "0" "$code"
hits=$(mock_slice hits "$before")
assert "click 639 430 が start_button に当たる" "start_button" \
  "$(printf '%s' "$hits" | jq -r '.value[-1].button')"
assert_between "click 639 430 の逆変換 x が 639±1" 638 640 \
  "$(printf '%s' "$hits" | jq -r '.value[-1].game.x | round')"
assert_between "click 639 430 の逆変換 y が 430±1" 429 431 \
  "$(printf '%s' "$hits" | jq -r '.value[-1].game.y | round')"

# --- 5. click-node ----------------------------------------------------------
before=$(mock_len hits)
out=$(gw click-node cell_1_2 2>&1)
code=$?
assert "click-node は exit 0" "0" "$code"
hits=$(mock_slice hits "$before")
assert "click-node cell_1_2 が cell_1_2 に当たる" "cell_1_2" \
  "$(printf '%s' "$hits" | jq -r '.value[-1].button')"

# --- 6. click-node（存在しない Control） ------------------------------------
out=$(gw click-node no_such_node --timeout 2000 2>&1)
code=$?
assert "存在しない Control の click-node は exit 1" "1" "$code"
assert_contains "存在しない Control は見つからないことを報告する" "見つからない" "$out"

# --- 7. key --hold（押下時間と logical/physical の両方） --------------------
before=$(mock_len keys)
out=$(gw key ArrowRight --hold 300 2>&1)
code=$?
assert "key --hold は exit 0" "0" "$code"
keys=$(mock_slice keys "$before")
assert_between "ArrowRight の keyup と keydown の差が 300±50 ms" 250 350 \
  "$(printf '%s' "$keys" | jq -r '
    ([.value[] | select(.code == "ArrowRight" and .type == "keyup")][0].t
     - [.value[] | select(.code == "ArrowRight" and .type == "keydown")][0].t) | round')"
kd=$(printf '%s' "$keys" | jq -c '[.value[] | select(.code == "ArrowRight" and .type == "keydown")][0]')
assert "ArrowRight の keydown の key は ArrowRight" "ArrowRight" "$(printf '%s' "$kd" | jq -r '.key')"
assert "ArrowRight の keydown の code は ArrowRight" "ArrowRight" "$(printf '%s' "$kd" | jq -r '.code')"
assert "ArrowRight の keydown の keyCode は 39" "39" "$(printf '%s' "$kd" | jq -r '.keyCode')"

# --- 8. key（英字 1 文字） --------------------------------------------------
before=$(mock_len keys)
out=$(gw key a 2>&1)
code=$?
assert "key a は exit 0" "0" "$code"
keys=$(mock_slice keys "$before")
kd=$(printf '%s' "$keys" | jq -c '[.value[] | select(.type == "keydown")][-1]')
assert "key a の keydown の key は a" "a" "$(printf '%s' "$kd" | jq -r '.key')"
assert "key a の keydown の code は KeyA" "KeyA" "$(printf '%s' "$kd" | jq -r '.code')"

# --- 9. keydown / keyup を個別に送る ---------------------------------------
before=$(mock_len keys)
out=$(gw keydown Shift 2>&1)
code=$?
assert "keydown Shift は exit 0" "0" "$code"
out=$(gw keyup Shift 2>&1)
code=$?
assert "keyup Shift は exit 0" "0" "$code"
keys=$(mock_slice keys "$before")
assert "ShiftLeft の keydown と keyup が順に記録される" "keydown,keyup" \
  "$(printf '%s' "$keys" | jq -r '[.value[] | select(.code == "ShiftLeft") | .type] | join(",")')"

# --- 10. shot ---------------------------------------------------------------
out=$(gw shot "${TMP}/shot.png" 2>&1)
code=$?
assert "shot は exit 0" "0" "$code"
if [ -s "${TMP}/shot.png" ]; then
  assert "shot の PNG が 0 バイトより大きい" "exists" "exists"
else
  assert "shot の PNG が 0 バイトより大きい" "exists" "missing-or-empty"
fi
out=$(gw shot "${TMP}/shot2.png" --jpeg 2>&1)
code=$?
assert "shot --jpeg は exit 0" "0" "$code"
assert "shot --jpeg の出力 path は .jpg" "${TMP}/shot2.jpg" "$(printf '%s' "$out" | jq -r '.path')"
if [ -s "${TMP}/shot2.jpg" ]; then
  assert "shot --jpeg のファイルが存在する" "exists" "exists"
else
  assert "shot --jpeg のファイルが存在する" "exists" "missing-or-empty"
fi

# --- 11. seq ----------------------------------------------------------------
# console-expect の needle は雛形の console.log("[mock] keydown", e.key, e.code) の連結結果に合わせる。
# Space の key は " " なので "[mock] keydown" + " " + " " + " " + "Space" で空白が 3 つ並ぶ
cat > "${TMP}/seq.txt" <<'EOF'
# テスト用シナリオ
console-clear
click 639 430
wait 100
key ArrowRight --hold 300
@1000 key Space
console-expect "[mock] keydown   Space" 3000
EOF
hits_before=$(mock_len hits)
keys_before=$(mock_len keys)
out=$(gw seq "${TMP}/seq.txt" 2>"${TMP}/seq.err")
code=$?
assert "seq は exit 0" "0" "$code"
assert "seq の console-expect が一致した文字列を返す" "[mock] keydown   Space" \
  "$(printf '%s' "$out" | jq -r '[.results[] | select(.op == "console-expect")][0].result.matched')"
hits=$(mock_slice hits "$hits_before")
assert "seq の click 639 430 が start_button に当たる" "start_button" \
  "$(printf '%s' "$hits" | jq -r '.value[-1].button')"
keys=$(mock_slice keys "$keys_before")
assert_between "seq の ArrowRight の押下時間が 300±50 ms" 250 350 \
  "$(printf '%s' "$keys" | jq -r '
    ([.value[] | select(.code == "ArrowRight" and .type == "keyup")][0].t
     - [.value[] | select(.code == "ArrowRight" and .type == "keydown")][0].t) | round')"
assert "seq の Space の keydown が記録される" "Space" \
  "$(printf '%s' "$keys" | jq -r '[.value[] | select(.code == "Space" and .type == "keydown")][0].code')"

# --- 12. seq（未知の操作） --------------------------------------------------
cat > "${TMP}/seq-bogus.txt" <<'EOF'
# 未知の操作を含むシナリオ
click 639 430
bogus 1
EOF
out=$(gw seq "${TMP}/seq-bogus.txt" 2>&1)
code=$?
if [ "$code" -ne 0 ]; then
  assert "未知の操作を含む seq は exit 非 0" "non-zero" "non-zero"
else
  assert "未知の操作を含む seq は exit 非 0" "non-zero" "0"
fi
assert_contains "未知の操作の失敗に行番号が入る" ":3" "$out"

# --- 13. probe-input --------------------------------------------------------
out=$(gw probe-input 2>&1)
code=$?
assert "probe-input は exit 0" "0" "$code"
assert "probe-input の received は true" "true" "$(printf '%s' "$out" | jq -r '.received')"

# --- 14. 到達できない CDP ---------------------------------------------------
out=$(bash "$SCRIPT" --cdp http://127.0.0.1:1/ --timeout 5000 status 2>&1)
code=$?
assert "誰も listen していない CDP は exit 1" "1" "$code"
assert_contains "CDP に到達できないことを報告する" "到達できない" "$out"

# --- 15. 引数なし -----------------------------------------------------------
out=$(bash "$SCRIPT" 2>&1)
code=$?
assert "引数なしは exit 2" "2" "$code"

# --- 16. 起動失敗（#status-notice に理由が入る） ---------------------------
# 以降はページを別の状態へ遷移させるため最後にまとめる
out=$(gw open "${BASE}/index.html?fail=WebGL2%20-%20Check" 2>&1)
code=$?
assert "起動失敗ページの open は exit 0" "0" "$code"
out=$(gw wait-started --timeout 3000 2>&1)
code=$?
assert "起動に失敗したページの wait-started は exit 1" "1" "$code"
assert_contains "起動失敗であることを報告する" "起動に失敗" "$out"
assert_contains "起動失敗の理由（notice の文字列）を報告する" "WebGL2" "$out"

# --- 17. 404 ページ（起動完了と誤判定しない） ------------------------------
out=$(gw open "${BASE}/nothing.html" 2>&1)
code=$?
assert "404 ページの open は exit 0" "0" "$code"
assert "404 ページの HTTP ステータスは 404" "404" "$(printf '%s' "$out" | jq -r '.status')"
out=$(gw wait-started --timeout 3000 2>&1)
code=$?
assert "404 ページの wait-started は exit 1" "1" "$code"
assert_contains "canvas が無いことを報告する" "canvas" "$out"

echo ""
echo "PASS: ${PASS} / FAIL: ${FAIL}"
[ "$FAIL" -eq 0 ]
