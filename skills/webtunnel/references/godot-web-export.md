# Godot の Web エクスポートを webtunnel で開く

Godot 4 の Web エクスポートを runner 上の Chromium で開き、agent-browser の CDP 接続で操作する時の、起動オプション・起動判定・座標の写し方。導入手順（caller workflow の `setup_command` / `start_command` の例）は PROJECT.md「新しいプロジェクトに webtunnel を導入する > Godot プロジェクトの例」を SSOT とし、ここには転記しない。

出典: 実測は https://github.com/bannzai/castle/issues/891 のコメント（2026-09-06、ubuntu-latest / Godot 4.7.stable / Google Chrome 152）。spike のスクリプト（`route-web.sh`）は https://github.com/bannzai/suicagamecopy/pull/16 。

## 起動オプション

`up <session> --software-webgl` で起動する（caller workflow が `software_webgl` input を宣言していること。宣言の無い input を送ると dispatch が拒否される）。Xvfb 上の headed Chromium は既定で WebGL2 が無効のため、フラグ無しでは Godot が `WebGL2 - Check web browser configuration and hardware support` で起動しない。付くフラグの内訳と固定リストにしている理由は PROJECT.md「ソフトウェア WebGL（SwiftShader）」。

## 起動の判定

Godot 既定の HTML シェル（`html/custom_html_shell` を指定していないエクスポート）は、起動に成功すると `#status` 要素を DOM から取り除き、失敗すると `#status-notice` に理由を入れて表示する。ページを開いた後、この状態が決まるまで待ってから操作に入る（実測: open から起動まで 3.1 秒。起動直後はまだ描画されないことがあるため、スクリーンショットは数秒置いてから撮る）。

```bash
CDP=http://<tailscale IP>:9222
agent-browser --cdp "$CDP" open http://localhost:8080/index.html
agent-browser --cdp "$CDP" eval 'JSON.stringify({started: document.getElementById("status") === null, notice: (document.getElementById("status-notice") || {textContent: ""}).textContent, webgl2: !!document.createElement("canvas").getContext("webgl2")})'
```

`started` が `true` になるまで数秒おきに繰り返す。`notice` に文字列が入ったら起動失敗で、その文字列が原因（WebGL2 無効なら `--software-webgl` の付け忘れ）。`webgl2` はページ側から見た WebGL2 の可否で、`--software-webgl` を付けたセッションでは `true` になる。

カスタムの HTML シェルを使うプロジェクトでは、そのシェルの起動表示に合わせて判定を書き換える。

## ゲーム座標をクリック座標に写す

Godot の canvas（既定シェルでは `id="canvas"`）はブラウザのビューポート全体に広がり、プロジェクトの表示解像度（`display/window/size/viewport_width` × `viewport_height`）のアスペクト比を保って中央に描かれる（stretch の aspect が `keep` の場合）。runner の Chromium のビューポートは 1280x656 で 16:9 ではないため、ゲーム座標をそのままクリック座標に使うと縦方向がずれる。canvas の `getBoundingClientRect()` からスケールとオフセットを計算して写す。

`GAME_W` / `GAME_H` はプロジェクトの表示解像度に置き換える（例: 1280 / 720）。

```bash
# ゲーム座標 (x, y) をブラウザ座標へ写す JS。GAME_W / GAME_H はプロジェクトの表示解像度
MAP_JS='(function(x,y){var r=document.getElementById("canvas").getBoundingClientRect();var s=Math.min(r.width/GAME_W,r.height/GAME_H);var ox=r.left+(r.width-GAME_W*s)/2;var oy=r.top+(r.height-GAME_H*s)/2;return JSON.stringify({x:Math.round(ox+x*s),y:Math.round(oy+y*s)});})'

# 例: ゲーム座標 (639, 430) のボタンをクリックする
pos=$(agent-browser --cdp "$CDP" eval "${MAP_JS}(639,430)" | tr -d '\n' | sed 's/^"//; s/"$//; s/\\"/"/g')
x=$(printf '%s' "$pos" | jq -r '.x')
y=$(printf '%s' "$pos" | jq -r '.y')
agent-browser --cdp "$CDP" mouse move "$x" "$y"
agent-browser --cdp "$CDP" mouse down left
agent-browser --cdp "$CDP" mouse up left
```

- `eval` の出力は JSON 文字列がさらに引用符で包まれることがあるため、`sed` で外側の引用符とエスケープを剥がしてから `jq` に渡す
- 実測（1280x720 基準のプロジェクト）: Start ボタン中心のゲーム座標 (639, 430) → ブラウザ座標 (639, 392)。横方向はスケール 1 でそのまま、縦方向はレターボックス分だけ上にずれる
- キー入力は座標に依存しないため `agent-browser --cdp "$CDP" press Space` のように直接送る。Godot 既定シェルは `html/focus_canvas_on_start=true` で起動時に canvas へフォーカスするが、クリックの後にキー入力が効かない時は canvas をクリックしてフォーカスを戻す
- マウスの移動自体がゲームの状態を変える（保持中のオブジェクトが動く等）場合、キー入力による画面差分を見る区間ではマウスを動かさない
- ウィンドウ高さをゲーム解像度 + ブラウザ UI 分（実測 144 px）にしてビューポートを揃えれば座標が 1:1 になるが、runner の Chromium のウィンドウサイズは input ではない（PROJECT.md「Godot プロジェクトの例」）

## 制約

- Web エクスポートで確認できるのは Web 版の挙動。デスクトップ固有（フルスクリーン切替・ゲームパッド・ファイル保存先）の確認は対象外
- 録画（Xvfb の画面全体）にはレターボックスも写る。ゲーム画面だけの画像が要るなら CDP のスクリーンショット後に切り出す
- SwiftShader の描画は CPU で行うため、描画負荷の高いシーンでは fps が落ちる。fps に依存する検証（アニメーションの時間計測等）には向かない
