# Godot の Web エクスポートを webtunnel で開く

Godot 4 の Web エクスポートを runner 上の Chromium で開き、CDP 接続で操作する時の、起動オプション・接続情報・起動判定・座標とキーの扱い・セッションの寿命。導入手順（caller workflow の `setup_command` / `start_command` の例）は PROJECT.md「新しいプロジェクトに webtunnel を導入する > Godot プロジェクトの例」を SSOT とし、ここには転記しない。

出典: 実測は https://github.com/bannzai/castle/issues/891 のコメント（2026-09-06、ubuntu-latest / Godot 4.7.stable / Google Chrome 152）。spike のスクリプト（`route-web.sh`）は https://github.com/bannzai/suicagamecopy/pull/16 。21 ゲームの実操作で毎回自作された補助と躓きは https://github.com/bannzai/castle/issues/952 （godotpractice の `documents/hearing/` と `documents/knowledge/`）。

## 操作は godot-web.sh で行う

座標変換・長押し・シナリオ再生・撮影は `scripts/godot-web.sh` にまとめてある（サブコマンドと引数は同スクリプトのヘッダーコメントが SSOT）。agent-browser を経由せず CDP に直接 WebSocket 接続するため、keydown → keyup の間隔を ms 単位で守れ、PNG の転送が詰まった時は JPEG に倒せる。agent-browser は同じ CDP に並行して接続してよい（`snapshot` 等はそちらで行う）。

```bash
GW="bash ${CLAUDE_SKILL_DIR}/scripts/godot-web.sh --session <session>"   # --cdp <URL> でも可
$GW open http://localhost:<port>/index.html
$GW wait-started                       # #status が消える (起動完了) まで待つ。失敗理由があれば表示して exit 1
$GW click 639 430                      # ゲーム座標 (1280x720 基準) をクリック
$GW key ArrowRight --hold 300          # keydown 送信の 300 ms 後に必ず keyup
$GW shot ./tmp/after.png               # PNG がタイムアウトしたら ./tmp/after.jpg に倒す
```

ゲームの表示解像度が 1280x720 以外なら `--game-size <WxH>`（または環境変数 `GODOT_WEB_GAME_SIZE`）で渡す。

## 起動オプション

`up <session> --software-webgl --wait` で起動する（caller workflow が `software_webgl` input を宣言していること。宣言の無い input を送ると dispatch が拒否される）。Xvfb 上の headed Chromium は既定で WebGL2 が無効のため、フラグ無しでは Godot が `WebGL2 - Check web browser configuration and hardware support` で起動しない。付くフラグの内訳と固定リストにしている理由は PROJECT.md「ソフトウェア WebGL（SwiftShader）」。

`--wait` と `--software-webgl` を併用すると、ready の直後に `scripts/godot-web-doctor.sh` が 1 回走り、runner → CDP → 配信 HTTP → 起動完了 → WebGL2 → 撮影 の順にどこまで通ったかを表示する（実入力の段階はタイトル画面を進めないよう省略。`WEBTUNNEL_NO_DOCTOR=1` で省略できる）。操作の途中で「撮影が返らない」「入力が効かない」となった時も、同じ doctor を `--session <session>` で手で走らせて段階を切り分ける（実入力の段階まで含めて判定する。既定で送るキーは Shift）。

## 配信ポートの確認

配信 URL の ポートは caller workflow（既定 `.github/workflows/browser-session.yml`）の `port` input の値で、リポジトリごとに違う。例の数字を写さず、実ファイルから読む（例示のポートへ接続して接続拒否で止まった事例が複数ある）。

```bash
gh api repos/<owner>/<repo>/contents/.github/workflows/browser-session.yml --jq '.content' | base64 -d | grep -E '^\s*port:'
```

`godot-web-doctor.sh` は `--url` / `--port` を省略すると、この手順で port を読んで `http://localhost:<port>/index.html` を組み立てる。セッションの `start_url` を省略した場合は Chromium が最初からその URL を開いている（PROJECT.md「dev サーバの起動」）。

## 起動の判定

Godot 既定の HTML シェル（`html/custom_html_shell` を指定していないエクスポート）は、起動に成功すると `#status` 要素を DOM から取り除き、失敗すると `#status-notice` に理由を入れて表示する。`godot-web.sh wait-started` がこの状態が決まるまで待つ（実測: open から起動まで 3.1 秒。起動直後はまだ描画されないことがあるため、スクリーンショットは数秒置いてから撮る）。`notice` に文字列が入ったら起動失敗で、その文字列が原因（WebGL2 無効なら `--software-webgl` の付け忘れ）。404 や別のページでは `#status` が最初から無いため、`canvas` の存在も起動の条件にしている。

手で確認する場合は `godot-web.sh status` が `started` / `notice` / `webgl2` / `viewport` / `canvas` の実寸を JSON で返す。カスタムの HTML シェルを使うプロジェクトでは `--canvas <selector>` で canvas を指定し、起動表示はそのシェルに合わせて `eval` で判定する。

## ゲーム座標をクリック座標に写す

Godot の canvas（既定シェルでは `id="canvas"`）はブラウザのビューポート全体に広がり、プロジェクトの表示解像度（`display/window/size/viewport_width` × `viewport_height`）のアスペクト比を保って canvas の内側に中央に描かれる（stretch の aspect が `keep` の場合。余白はエンジン側で作られ、CSS ではない）。runner の Chromium のビューポートは 1280x656 で 16:9 ではないため、ゲーム座標をそのままクリック座標に使うと縦方向がずれる。`godot-web.sh click` は canvas の `getBoundingClientRect()` から縮尺 `min(canvas.width / GAME_W, canvas.height / GAME_H)` と中央寄せのオフセットを計算して写す（`map <x> <y>` で変換結果だけを見られる）。

- 実測（1280x720 基準のプロジェクト）: Start ボタン中心のゲーム座標 (639, 430) → ブラウザ座標 (639, 392)。縮尺 0.911、横のオフセット 57 px、縦のレターボックス 0 px
- Control の名前で操作したい場合（`click-node <name>`）は、`references/godot_web_diag.gd` をプロジェクトの Autoload に追加する。Web エクスポートでだけ動き、`window.__godotWebDiag` 経由で `Control.get_global_rect()` を返す（前提と対象外は同ファイルのコメント）
- マウスの移動自体がゲームの状態を変える（保持中のオブジェクトが動く等）場合、キー入力による画面差分を見る区間ではマウスを動かさない（`mouse-move` は明示した時だけ動く）
- ウィンドウ高さをゲーム解像度 + ブラウザ UI 分（実測 144 px）にしてビューポートを揃えれば座標が 1:1 になるが、runner の Chromium のウィンドウサイズは input ではない（PROJECT.md「Godot プロジェクトの例」）

## キー入力: logical key と physical key

Godot の Web 版は DOM の `KeyboardEvent.code` を physical keycode、`KeyboardEvent.key` を keycode として読む。`code` が欠けたイベントは Chromium が keyCode から補うため、`ArrowRight` を送ったつもりが physical `KeyA`（A）として届き、InputMap の physical 割り当てで左に動く事故が起きる（godotpractice platformer: `agent-browser keydown ArrowRight` が physical_keycode=65 になった）。InputMap を逆に変えて合わせてはいけない。

- `godot-web.sh key / keydown / keyup` は `key` と `code` と VK コードを揃えて送る（対応するキー名はスクリプトのヘッダーコメント）。矢印キーもこの経路なら physical が一致する
- agent-browser を使う場合は `press ArrowRight`（押して離す）は一致し、`keydown ArrowRight` は一致しない環境がある。長押しが要るなら `godot-web.sh key <Key> --hold <ms>` を使う
- 押下時間: リモート経由で `keydown` の応答を待ってから時間を数えると、通信時間が押下時間へ加算されて歩数がずれる（farmsim）。`key --hold` は keydown を送った時刻から数え、指定 ms 後に必ず keyup を送ってから両方の応答を待つ
- `key` の hold 無し（`agent-browser press` も同じ）は押下と解放が同一描画フレームに収まることがあり、1 回の入力を Godot が取りこぼす・逆に「Enter 1 回で 2 段進む」の切り分けができない。移動・通常技は `--hold 50` 程度で複数フレーム空け、波動拳のような連続入力は `seq` で 80 ms 間隔の `keydown` / `wait` / `keyup` を並べる（fighter の実測: 0.65 秒以内のコマンドは 80 ms 間隔で実装と同じ入力履歴になる）
- クリックの後にキー入力が効かない時は canvas をクリックしてフォーカスを戻す（Godot 既定シェルは `html/focus_canvas_on_start=true` で起動時に canvas へフォーカスする）

## 入力シナリオ（seq）

タイトル → プレイ → 結果のような一連の操作は、1 行 1 操作のシナリオファイルにして `godot-web.sh seq <file>` で再生する（行の形式はスクリプトのヘッダーコメント）。`@<ms>` でシナリオ開始からの絶対時刻を指定でき、`console-expect "<文字列>"` でゲームの `print()` が console に出たことを確認し、`shot` で途中の画面を残せる。実行ログ（各行の経過時間と結果）は stderr に出る。

## 撮影が返らない時

Tailscale 越しの PNG 転送が数分応答しなくなる事例が多発した（5 ゲームが直接 CDP で JPEG 撮影に切り替えた）。`godot-web.sh shot <path> --timeout <ms>` は PNG がタイムアウトすると自動で JPEG（`<path の拡張子を .jpg に>`）に倒す。最初から JPEG でよければ `--jpeg`（`--quality` で品質）。録画（Xvfb の画面全体）にはレターボックスも写るため、ゲーム画面だけの画像が要るなら撮影後に切り出す。

## セッションの寿命と再開

- セッションは `duration_minutes`（既定 60 分）で自動終了する。起動してから作業に入るまでに時間を空けると期限切れになる（roguelike）。`up` は操作を始める直前に行い、長い作業は `--duration` を延ばす
- 繋がらなくなった時は、まず既存セッションが生きているかと実際の CDP アドレスを確認する: `webtunnel-cli.sh list` で tailnet と run の状態、`webtunnel-cli.sh cdp <session>` で現在の IP。run を作り直すと tailscale IP が変わるため、古い IP を保持したまま接続しない
- `up --wait` 中の「run が存在しない」と GitHub API の一時エラーは別物。`local/webtunnel` は API の取得失敗を run 不在と判断せず待機を続ける。`godot-web-doctor.sh` の runner 段階も両者を分けて表示する。手で確認する時は `gh run list -R <owner>/<repo> -w browser-session.yml` の exit code と出力を分けて見る
- agent-browser のデーモンは `--session` 名ごとに前回の CDP アドレスを保持する。run を作り直した後に同じセッション名で接続すると旧アドレスを掴んだままになるため、`agent-browser --session <name> close` でそのセッションだけ閉じてから接続し直す（`close --all` は他の worktree の作業を壊す）。セッション名は worktree 単位（`~/.claude/rules/agent-browser-session-naming.md`）にし、複数 worktree のデーモンが混ざらないようにする。`godot-web.sh` は接続を保持しないため、この問題は起きない

## 制約

- Web エクスポートで確認できるのは Web 版の挙動。デスクトップ固有（フルスクリーン切替・ゲームパッド・ファイル保存先）の確認は対象外
- SwiftShader の描画は CPU で行うため、描画負荷の高いシーンでは fps が落ちる。fps に依存する検証（アニメーションの時間計測等）には向かない
