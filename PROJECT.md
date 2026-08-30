# WebTunnel

GitHub Actions の Linux Runner 上で Chromium を起動し、Tailscale 経由でローカルの agent-browser から CDP（Chrome DevTools Protocol）で操作・動作確認するためのツール群。[simtunnel](https://github.com/bannzai/simtunnel)（iOS Simulator 版）の Web 版であり、セキュリティ設計は simtunnel の PROJECT.md「リポジトリ公開に耐える安全性」を横展開している。

本ファイルが設計の SSOT。設計に関わる変更をしたら同じ変更で本ファイルも更新する。

## 目的

- ローカルマシンのリソースを消費せずに、ブラウザでの動作確認を GHA runner 上で行う
- agent-browser の CDP 接続（`--cdp`）で、tailnet 越しに runner 上の Chromium を操作する
- セッション中の画面をリアルタイムに見られるようにし、人間が挙動を目で確認できるようにする
- 動作確認の過程（録画）を artifact として残し、PR に添付できるようにする

## アーキテクチャ

```text
ローカル (macOS)                          GitHub Actions (ubuntu-latest)
┌──────────────────────┐                 ┌───────────────────────────────────┐
│ local/webtunnel CLI  │ gh workflow run  │ browser-session.yml (dispatch)    │
│ agent-browser --cdp ─┼───┐             │  └─ session.yml (reusable)        │
│ ブラウザ (preview) ──┼─┐ │             │      dev サーバ 127.0.0.1:5173    │
└──────────────────────┘ │ │  tailnet    │      Xvfb :99 (1280x800)          │
                         │ │             │      └─ Chromium (headed)         │
                         │ │             │          開く先 localhost:5173    │
                         │ │             │          CDP 127.0.0.1:9222       │
                         │ └─────────────┼──→ socat: TS_IP:9222 → 127.0.0.1  │
                         │               │      preview 127.0.0.1:9100       │
                         └───────────────┼──→ socat: TS_IP:9100 → 127.0.0.1  │
                           (Tailscale)   │      ffmpeg x11grab → artifact    │
                                         └───────────────────────────────────┘
```

- runner は ephemeral node として tailnet に参加し、ホスト名は `webtunnel-<session>` になる
- CDP はローカルの 127.0.0.1:9222 で待ち受け、socat で tailscale インターフェースへ中継する
- dev サーバは runner の localhost だけで動かし、tailnet には出さない（見るのは同じ runner 上の Chromium のため）
- preview（ライブ映像）は 127.0.0.1:9100 で待ち受け、CDP と同じく socat で中継する
- 録画は Xvfb の画面全体を ffmpeg (x11grab) で撮り、セッション終了時に artifact `recording-<session>` へアップロードする

## 設計判断

### トンネル: Tailscale を採用

要件は「public リポジトリでも安全」。CDP は無認証の操作 API なので、到達できる = ブラウザを完全に操作できる（任意 URL の閲覧・Cookie の読み出し・JS 実行）。よって「エンドポイントを公開しない」ことが唯一の安全な設計になる。simtunnel での比較検討（Cloudflare Tunnel / ngrok / reverse SSH はいずれも公開エンドポイントか追加インフラが必要）をそのまま流用し、Tailscale を採用する。認証も simtunnel と同一の OIDC（workload identity federation）で、長期シークレットを GitHub に保存しない。

### CDP の Host ヘッダ制約

Chromium の DevTools HTTP エンドポイント（`/json/version` 等）は、Host ヘッダが IP アドレスか localhost 以外のリクエストを `Host header is specified and is not an IP address or localhost` で拒否する。MagicDNS 名（`http://webtunnel-<session>:9222`）では接続できないため、**接続は必ず tailscale IP で行う**。

- `local/webtunnel` CLI は `tailscale status` からセッションの IP を引いて接続する
- `/json/version` が返す `webSocketDebuggerUrl` は Host ヘッダをそのまま echo するため、IP で GET すれば後続の WebSocket 接続も同じ IP（= socat bridge 経由）になり、一貫して疎通する

### 録画: Xvfb + headed Chromium + ffmpeg (x11grab)

headless でも CDP 操作は可能だが、「動作確認の過程を artifact に残す」ために Xvfb 上で headed 起動し、画面全体を ffmpeg で録画する方式にした。

- CDP の `Page.startScreencast` でも録画は可能だが、フレームを受け続ける常駐クライアントが runner 上に必要になる。x11grab は Chromium と独立に動き、操作レイヤー（agent-browser）に要求を足さない
- ジョブが猶予なく殺されても途中まで再生できるよう fragmented MP4（`-movflags +frag_keyframe+empty_moov`）で書き出す
- `webtunnel down`（`gh run cancel`）でも録画が残るよう、停止・アップロードの step は `if: always()` にする（cancel 後も `always()` の step は猶予時間内で実行される）

### preview（ライブ映像）: 自前の MJPEG サーバを専用ポートで配信

録画は artifact なのでセッション終了後にしか見られず、スクリーンショットは 1 枚ずつで連続的な挙動（アニメーション・遷移の途中）を追えない。セッション中の画面をそのまま見る経路として、Xvfb の画面を MJPEG で流す小さな HTTP サーバ（`runner/preview-server.py`）を :9100 に置き、CDP と同じく socat で tailnet へ中継する。

- **serve-sim（simtunnel が使う preview UI）は使わない**: iOS Simulator 専用であり Xvfb の X 画面は配信できない。また serve-sim は shell-exec route を持つため、tailnet 内とはいえ露出を増やしたくない。webtunnel の preview サーバは閲覧ページとストリームの 2 経路だけを持つ
- **CDP 内蔵の DevTools frontend（`/devtools/inspector.html`）は使わない**: 画面共有（Screencast）を含む完全な操作 UI が手に入るが、frontend 本体が数 MB あり DERP relay の細い帯域では開くだけで待たされる。「今どうなっているか」を見る用途には重い
- **`Page.startScreencast` は使わない**: フレームを受け続ける常駐クライアントが必要になる。x11grab なら Chromium と独立に動き、操作レイヤー（agent-browser）に要求を足さない。録画（`start-recording.sh`）と同じ理由
- ストリームは接続ごとに ffmpeg を 1 本起動し、fps / 解像度 / quality をクエリで変えられる。帯域が細い環境で「粗くて滑らか」と「精細で飛び飛び」を見る側が選べるようにするため。runner の CPU を食い潰さないよう同時視聴は 2 本までに制限する
- **操作は preview からは行わない**（見るだけ）。クリックやキー入力は CDP（agent-browser）で行う経路がすでにあり、preview に入力を足すと無認証の操作面が 2 つになる

### 操作レイヤー: agent-browser の CDP 接続（自作 MCP は作らない）

simtunnel は WDA を喋る薄い MCP（simtunnel-mcp）を自作したが、webtunnel では不要。agent-browser が `--cdp <url>` で外部ブラウザへの接続を標準サポートしており、snapshot / screenshot / click 等の操作が全てそのまま動く。ローカルの agent-browser が CDP クライアントになるため、runner 側に追加の受け口も要らない。

```bash
# --session は作業スペース名（~/.claude/rules/agent-browser-session-naming.md）
agent-browser --session "$(basename "$(git rev-parse --show-toplevel)")" \
  --cdp http://<tailscale IP>:9222 open https://example.com
```

### dev サーバの起動

動作確認の対象は caller リポジトリのプロジェクトであり、runner 上で dev サーバを起動して Chromium から `http://localhost:<port>` を開く。simtunnel の `build_project` / `build_scheme` 相当を Web 向けに置き換えた input を `session.yml` に持たせる。

| input | 役割 |
|---|---|
| `setup_command` | dev サーバ起動前のセットアップ（例: `npm ci`）。空ならスキップ |
| `start_command` | dev サーバの起動（例: `npm run dev`）。空なら dev サーバを起動しない |
| `working_directory` | 上記 2 つを実行する caller リポジトリルート相対のディレクトリ |
| `port` | dev サーバが listen するポート |
| `ready_path` | ready 判定に使うパス |
| `node_version` | `actions/setup-node` で用意する Node のバージョン。空なら runner のプリインストール版 |
| `extension_path` | Chromium に読み込む Chrome 拡張（unpacked）のディレクトリ。空なら読み込まない（「Chrome 拡張の読み込み」参照） |

- **ポートは `PORT` 環境変数として両コマンドへ渡す**。`port` input を SSOT にして、コマンド文字列側にポート番号を重複させない。Next.js / Nuxt / CRA は `PORT` をそのまま解釈し、Vite は `vite.config.js` で `process.env.PORT` を読む
- **ready 判定は `http://127.0.0.1:<port><ready_path>` への到達**とし、HTTP ステータスは問わない（応答がある = listen している）。dev サーバのプロセスが死んだら待たずに即失敗させ、ログ末尾を step の出力に出す。ready 後もプロセス ID を keepalive に引き継いで監視し、死んだらセッションを終了する（動作確認の対象が消えたセッションを維持しない）
- **ツールチェーン準備は session.yml 側**に持つ。reusable workflow の呼び出しは job 単位で、caller は job の中に step を差し込めないため。Node 以外（Python / Ruby / Go 等）は ubuntu-latest のプリインストール版を `setup_command` から使う
- **ビルド成果物を artifact 経由で受け取る経路（simtunnel の `app_artifact` 相当）は作らない**。simtunnel でこれが要るのは、macOS runner が高価でビルドを別 job に切り出す動機があり、かつ Flutter 等が `xcodebuild` 直叩きで表現できないため。Web は `setup_command` に任意のシェルコマンドを書けて Linux runner も安価なため、同一 job でビルドすれば足りる。必要になったら caller 側の build job + `download-artifact` を足す
- `start_url` を省略した時は `http://localhost:<port>/` を開く。dev サーバを起動しない場合だけ `about:blank` になる
- dev サーバのログ（`setup_command` の分と起動後の分）は artifact `dev-server-log-<session>` に残す。セッション中のランタイムエラーも down 後に追える
- **dev サーバは 127.0.0.1 で listen していることを検証してから tailnet に参加する**。0.0.0.0 で listen していると Tailscale 参加後に dev サーバが tailnet へ露出するため、ready 後に `ss` で loopback 以外の listener を検出したら失敗させる（caller は vite の `server.host` や `next dev -H 127.0.0.1` 等で loopback に束縛する）
- **caller のコマンドに OIDC トークンの発行能力を渡さないハードニング**。`id-token: write` の job で `setup_command` が走らせる依存パッケージの install script が Tailscale の trust credential に使える token を発行するのを防ぐ。start-dev-server.sh は `ACTIONS_ID_TOKEN_REQUEST_*` を外し、`GITHUB_ENV` 等を使い捨てファイルへ向けた env で caller を実行する（完全な隔離ではない。「リポジトリ公開に耐える安全性」の残存リスク参照）
- **起動前にポートが応答していたらエラーにする**（冪等成功にしない）。runner は毎回クリーンな VM のため、dev サーバ起動前の応答は別プロセスがポートを握っている異常。成功扱いにすると Chromium が無関係なサービスを開き、監視もされないまま ready になる
- **runner スクリプトの checkout は `.webtunnel-runner` に置く**。checkout はパス先の既存内容を消すため、caller リポジトリに実在しうる名前を避ける。`.webtunnel/` はログイン用セットアップスクリプト（`.webtunnel/setup.sh`。「ログイン済み状態でのセッション開始」参照）の置き場所として caller 側に予約するため checkout 先にしない。それでも `.webtunnel-runner` が存在する場合は checkout 前に検出して失敗させる（黙って caller の内容を消さない）
- **`up --wait` の待機は既定 40 分**（`WEBTUNNEL_WAIT_MINUTES` で変更可）。dev サーバ起動 15 分 + Chromium 起動 10 分 + セッション初期化（ログイン）15 分の step 上限と Tailscale のセットアップを覆う。run が消えた場合は即終了するため、長い既定でも失敗検知は遅れない。run が失敗・cancel で消えた場合は締め切りを待たずに終了する

### Chrome 拡張の読み込み

拡張を入れた状態でしか再現しない挙動（content script によるページ書き換え・popup の表示）を確認するために、`extension_path`（caller リポジトリルート相対の unpacked 拡張ディレクトリ）を持たせる。非空なら `start-chromium.sh` が `--disable-extensions-except=<絶対パス> --load-extension=<絶対パス>` を付けて Chromium を起動する。

- **拡張のビルドは `setup_command` に任せる**（例: `cd chrome-extension && npm ci && npm run build`）。dev サーバのビルドと同じ考え方で、拡張専用のビルド経路は作らない。`extension_path` に渡すのはビルド済みのディレクトリ（`chrome-extension/dist` 等）
- **拡張を読み込む時だけ Chromium をバイナリ選択の第一候補にする**。branded な Google Chrome は 137 以降 `--load-extension` / `--disable-extensions-except` を無視する（Chromium と Chrome for Testing は従来どおり動く）。ubuntu runner は `google-chrome` と `chromium`（Chromium スナップショットへの symlink）の両方を持つため、優先順を入れ替えるだけで足りる。それでも branded な Chrome 137+ しか無い環境では、拡張なしで黙って起動して誤った動作確認をしないよう起動前に失敗させる
- **拡張 ID を導出してステップサマリに出す**。unpacked 拡張の ID は拡張ディレクトリの絶対パスの SHA-256 先頭 16 バイトを `0-f` → `a-p` に写した値で決まるため、runner 側で計算して `chrome-extension://<id>/` を出力する。popup の確認は CDP でこの URL（`chrome-extension://<id>/popup.html`）を直接開いて行う（`chrome://extensions` は CDP から開いても中身を操作できず、`chrome.management` も CDP からは呼べない）。manifest に `key` がある拡張は ID が key 由来になるため導出しない
- **存在しないディレクトリ・`manifest.json` の無いディレクトリは起動前に失敗させる**。Chromium は読み込みに失敗しても「拡張なし」で起動してしまい、拡張が効いていない画面を正常と誤認するため
- 自己検証用のサンプル拡張を `webExtension/`（popup だけを持つ最小の Manifest V3 拡張）に置く。`browser-session.yml` に `-f extension_path=webExtension` を渡すと読み込まれ、popup の URL がステップサマリに出る

### 自己検証用のサンプル Web アプリ（webProject）

`webProject/` に Vite の最小サンプルアプリを置き、`browser-session.yml` の `sample_app`（既定 `true`）でこれを dev サーバとして起動する。simtunnel の `iOSProject/` + `sample_app` と同じ位置づけで、外部サイトに依存せず webtunnel 単体で「起動 → 操作」まで検証できる。

- 動作確認で意味を持つ要素を 1 ページに置く: クリックで変わるカウンタ、フォーム入力、日本語テキスト（CJK フォント確認）、非同期に更新される要素（`public/items.json` の fetch と経過秒数）
- runner の Chromium（1280x800 のウィンドウ = 高さ 650px 前後のビューポート）でスクロールせずに全要素が入るレイアウトにする。録画・スクリーンショットに全要素が写るため
- 依存は Vite のみ。dev サーバ起動の input（`setup_command` = `npm ci` / `start_command` = `npm run dev` / `node_version`）を実際に通す検証対象を兼ねる

### ログイン済み状態でのセッション開始

多くのプロダクトは主要画面がログインの向こう側にあるため、ログイン不要な画面しか触れないとセッションの用途が限られる。simtunnel の「オンボーディング突破用 Maestro flow の自動実行」と同じ考え方で、**定型のログインを runner 側のセットアップスクリプトに任せ、セッションはログイン済みの状態から始める**。

- **自動検出**: caller repo に `.webtunnel/setup.sh` があれば実行、なければスキップ。パスは `setup_script` input で差し替えられる（`local/webtunnel up <session> --setup-script <path>`）
- **実行順序は dev サーバ・Chromium の起動後 → 録画開始前 → tailnet 参加前**。ログイン対象が runner 上の dev サーバでも到達でき、認証情報の露出を止める要（後述）になる順序であり、入れ替えてはいけない
- **操作は agent-browser の CDP 接続**: 自前の CDP クライアントは作らない（「操作レイヤー」の判断をそのまま適用）。`run-auth-setup.sh` が runner に agent-browser を版指定で入れ、`WEBTUNNEL_CDP_URL`（`http://127.0.0.1:9222`）を環境変数で渡す。cwd は caller repo の workspace ルート
- **セットアップの失敗でセッションを潰さない**: 失敗しても run summary に警告を出してセッションは開く。ローカルの agent-browser から手動でログインする余地が残るため、セッション自体の価値は失われない。ハングも同様で、打ち切りは step の `timeout-minutes` ではなくスクリプト内の `timeout`（agent-browser のインストール 180 秒・セットアップスクリプト 480 秒。`INSTALL_TIMEOUT_SECONDS` / `SETUP_TIMEOUT_SECONDS` で変更可）で行う。step ごと殺されると録画・tailnet 参加・keepalive まで飛んでセッションが開かなくなるため、step の `timeout-minutes: 15` は最終防衛線に留める。セットアップスクリプトの打ち切りはプロセスグループごと行い、ハングした子プロセス（復号済みの資格情報を環境に持つ）を残さない。スクリプトが起動する常駐プロセス（dev サーバ等）は、スクリプト側で `setsid` によりグループから切り離して生かす（`examples/auth-demo/setup.sh` 参照）。**唯一の例外**として、失敗後に画面を about:blank へ戻せたと検証できない場合は、認証情報が録画・preview・CDP に露出しうるためセッションを開かず中断する
- **セットアップスクリプトも `start-dev-server.sh` と同じハードニングで実行する**: OIDC 発行能力（`ACTIONS_ID_TOKEN_REQUEST_*`）を外し、GitHub の永続化ファイル（`GITHUB_ENV` 等）をデコイに向けた env で走らせる（「リポジトリ公開に耐える安全性」の 11 参照）
- 実装は `runner/run-auth-setup.sh`、サンプル兼検証用のセットアップスクリプトは `examples/auth-demo/`

#### 認証情報の受け渡し

認証情報は secret `WEBTUNNEL_AUTH_ENV` で渡す。**`KEY=VALUE` を並べたものを base64 で単一行にした値**を登録し、`run-auth-setup.sh` が復号してセットアップスクリプトの環境変数にする。

```bash
printf 'APP_LOGIN_EMAIL=dev@example.com\nAPP_LOGIN_PASSWORD=xxxx\n' | base64 |
  gh secret set WEBTUNNEL_AUTH_ENV -R <owner>/<repo>
```

複数行の secret がログでどう伏字になるかに依存しない設計にするため、base64 で単一行に畳む。復号後の値は 1 つずつ `::add-mask::` に登録してから環境変数にするため、**セットアップスクリプトが誤って出力しても Actions ログでは伏字**になる。add-mask はジョブ全体に効くので、以降の step（`keepalive.sh` が出す chrome.log の末尾など）でも同じく伏字になる。

値は最初の `=` から行末までを**生のまま**渡す。引用符・エスケープの構文は無いため、値を `"..."` で囲まない（囲むと引用符も値の一部になる）。環境変数は agent-browser のインストール後・セットアップスクリプトの直前に export し、npm の lifecycle スクリプト（サードパーティコード）には見せない（復号前の `WEBTUNNEL_AUTH_ENV` の生値も npm の環境から外す）。`GITHUB_*` / `PATH` 等の制御用変数名のキーは、スクリプトや後続コマンドの挙動を secret の値で乗っ取れてしまうため警告して無視する。

#### 認証情報を Actions のログ・artifact に残さないための設計

1. **渡してよいのは開発環境用アカウントの資格情報だけ**: 本番アカウント・個人アカウントの資格情報を `WEBTUNNEL_AUTH_ENV` に入れない。runner は使い捨てとはいえ、ログイン後の画面は録画に残る
2. **ログイン操作は録画しない**: セットアップは録画開始前に走るため、入力中のフォーム（ユーザー名の表示・パスワードの打鍵）は録画に一切写らない。録画は「ログイン済みの画面」から始まる
3. **セットアップ失敗時は about:blank に戻し、戻せなければセッションを中断する**: 失敗するとユーザー名が見えたままのフォームが画面に残り、録画・preview・CDP に写り込む。`run-auth-setup.sh` は失敗時に CDP を直接叩いて空タブ以外を全て閉じ、残数で検証してから録画開始へ進む。検証できない場合は step を失敗させ、tailnet 参加ごと止める
4. **パスワード保存バブルを抑止する**: ログイン後に Chrome が出す「パスワードを保存しますか?」バブルはユーザー名を平文で表示し、閉じるまで画面に残る。録画開始前にログインを終えてもこのバブルは残り続けるため、実測で録画の全フレームに写り込んだ。`start-chromium.sh` がプロファイルの `credentials_enable_service` / `password_manager_enabled` を無効にして出さないようにする（抑止する起動 switch は無い）
5. **ログの伏字は add-mask で担保する**: 上記のとおり復号した値を個別に登録する。セットアップスクリプト側でも `set -x` を使わない
6. **artifact は録画だけ**: アップロードするのは `webtunnel-recording.mp4` のみで、セットアップの生成物（サーバのログ等）は artifact に含めない。dev サーバのログ artifact（`dev-server-log-<session>`）も、認証情報を渡したセッションではアップロードしない。dev サーバがリクエスト内容や認証診断をログへ書くと復号済みの資格情報がファイルに残りうるが、add-mask は Actions ログの表示にしか効かず artifact のファイル内容は伏字にならないため
7. **tailnet 参加前に完了する**: ログインは tailnet に出る前に終わるため、認証のやり取りが tailnet 上を流れることもない

なお、**認証情報を Actions へ一切渡さない経路**もある。セッションが ready になった後、ローカルの agent-browser で cookie / storage state を注入する方法で、runner 側の変更も secret の登録も要らない。ローカルで一度ログインして保存した状態をそのまま持ち込む用途に向く。

```bash
agent-browser --cdp http://<tailscale IP>:9222 --state ./tmp/state.json open http://localhost:3000
```

#### 対応方法の優先順位

ログインが必要なページへの対応は、次の順で検討する:

1. **サービス側の dev 限定の工夫（secret 不要）**: dev 環境の匿名認証・自動ログイン・dev DB にしか存在しないテストアカウント等で、ログインの壁自体を無くす。対象サービスを自分で変えられる場合の第一候補
2. **ローカル注入（Actions に資格情報を置かない）**: 上記の storage state 注入。ローカルで一度ログインした状態を持ち込む
3. **`WEBTUNNEL_AUTH_ENV` + セットアップスクリプト**: 前の2つが使えない場合（変えられない外部サービス、ログインフロー自体の検証）の汎用経路

1 を作り込む時は **dev 限定の仕掛けを本番に漏らさない**。自動ログインやテストアカウントは環境変数・ビルドフラグで dev 環境だけ有効にし、本番ビルド・本番 DB には入れない。アプリ側リポジトリが public ならその工夫のコード自体も公開されるため、知られても無害な設計（dev 環境にしか存在しないアカウント等）にする。3 の secret に本番・個人アカウントの資格情報を入れないのと同じ理由で、録画 artifact は公開される前提で扱う（「リポジトリ公開に耐える安全性」参照）。


### 利用者向け skill はこのリポジトリに置き、symlink で設置する

simtunnel の skill（`macos-simtunnel` / `ios-simulator`）は dotfile リポジトリ（bannzai/castle）に実体を置いているが、webtunnel の skill は**本リポジトリの `skills/` に実体を置く**。CLI（`local/webtunnel`）・workflow・runner スクリプトと同じ変更で skill を更新でき、実装と入口がずれないため。

- グローバルへの設置は `skills/install.sh` による symlink（`~/.claude/skills` / `~/.agents/skills` / `~/.codex/skills` のうち存在するもの）。dotfile リポジトリ側にはリンクだけが残る
- skill から CLI を呼ぶ経路は `skills/webtunnel/scripts/webtunnel-cli.sh` に集約する。自身の実体パスからリポジトリルートを辿るため、clone 先や symlink 経由の設置に依存しない
- ローカルブラウザとリモート（webtunnel）の使い分けは `agent-browser` skill から webtunnel skill へ誘導する（判断基準の SSOT は webtunnel skill の Phase 1）

### リポジトリ公開に耐える安全性

リポジトリは public で運用する（Linux runner 無料）。tailnet 内の実 IP 等の環境固有情報は、このリポジトリにも **run のログ・ステップサマリにも**書かない（後者は public リポジトリでは誰でも読める）。simtunnel の PROJECT.md「リポジトリ公開に耐える安全性」と同一の原則を適用する:

1. **公開エンドポイントゼロ**: CDP（:9222）も preview（:9100）も無認証のため、tailnet 内からしか到達できないようにする。runner 上ではどちらも 127.0.0.1 で待ち受け、tailscale インターフェースへの公開は `bridge.sh` の socat だけが行う
2. **トリガーは `workflow_dispatch` のみ**: 起動できるのは write 権限者だけ。fork からの PR には Secrets / OIDC トークンの権限が渡らない
3. **長期シークレットを持たない（OIDC / workload identity federation）**: Tailscale への認証は、GitHub が workflow に発行する短命の OIDC トークンで行う。subject が credential に登録した値に一致する workflow しか認証できず、盗まれて困る静的シークレットがそもそも存在しない（Secrets の `TS_OIDC_CLIENT_ID` / `TS_OIDC_AUDIENCE` は識別子であり秘密情報ではない）
4. **Tailscale ACL で双方向を絞る**: `tag:ci` からの発信は全拒否（simtunnel セットアップ時に設定済みのポリシーをそのまま使う。webtunnel 固有の追加設定は不要）
5. **ACL 設定 → runner 参加の順序は入れ替え不可**: simtunnel の Phase 0 で設定済みのため webtunnel では新規作業なし
6. **ephemeral node**: ジョブ終了と同時に tailnet から自動削除される。また workflow は CDP がローカルで応答してから tailnet に参加する（tailnet 内にいる時間を最小化）
7. **`timeout-minutes` でセッション上限**: 消し忘れても最大 6 時間で必ず落ちる
8. **サードパーティ action は commit SHA で固定**: `uses:` はフルレングスの commit SHA + バージョンコメントで固定する。バージョン更新時は `gh api repos/<owner>/<repo>/git/ref/tags/<tag>` で SHA を確認して書き換える
9. **runner スクリプトは workflow と同一 commit に固定**: reusable workflow（session.yml）は runner スクリプトを `job.workflow_repository` / `job.workflow_sha` で checkout する。caller が `uses:` を SHA 固定していれば、実行されるスクリプトも同じ SHA に固定される
10. **録画 artifact は公開される前提で使う**: public リポジトリの artifact はリポジトリの read 権限で取得でき、public repo では GitHub にログインした誰でもダウンロードできる（保持 7 日）。preview・CDP は tailnet 内限定だが、同じ画面が録画にも映るため、セッション画面に映すのは公開されてよい内容に限る。ログイン等の秘匿情報を扱う確認は `up --no-record` で録画を無効にする
11. **caller のコマンドへ OIDC 発行能力を渡さないハードリング（完全な隔離ではない）**: `session.yml` の job は Tailscale 認証に `id-token: write` を持つため、`setup_command` / `start_command`（依存パッケージの install script を含む）が OIDC トークンを発行できると、tag:ci の auth key を mint できてしまう。`start-dev-server.sh` は caller のコマンドを (a) `ACTIONS_ID_TOKEN_REQUEST_*` を外し、(b) `GITHUB_ENV` / `GITHUB_PATH` / `GITHUB_OUTPUT` / `GITHUB_STATE` を使い捨てファイルへ向けた env で実行し、現ステップでの発行と後続ステップへの環境注入（`BASH_ENV` 等）の両経路を塞ぐ。**ただし同一 VM・`sudo` NOPASSWD のため完全な隔離ではない**（悪意ある caller は別 step のプロセスを覗く等で回避しうる）。残存リスクを受け入れられるのは次の多層防御による: mint できるのは tag:ci の auth key のみ / tag:ci は ACL で発信全拒否 / ephemeral node で即削除 / credential は caller repo 単位にスコープ。完全分離は別 job かコンテナ隔離が要るが、dev サーバは session job と同じ runner の localhost で動かす必要があり（tailnet に出さないため）今回は採らない
12. **セッションに持ち込む認証情報を漏らさない**: base64 単一行の secret + `add-mask`、ログイン操作を録画開始前に済ませる順序、開発環境用アカウント限定の運用で担保する（「ログイン済み状態でのセッション開始」の「認証情報を Actions のログ・artifact に残さないための設計」）
13. **tailnet の実 IP を run のログ・サマリに出さない**: public リポジトリの run のログ・ステップサマリは誰でも読める。到達には tailnet への参加が要るため IP 単体で侵入できるわけではないが、環境固有情報を公開しない原則をログにも適用する。接続先の IP はローカルの `webtunnel cdp <session>` が `tailscale status` から引くため、runner 側が出力する必要はない（`session.yml` のセッション情報出力と `bridge.sh` の両方が対象）

### 各アプリ repo での実行（reusable workflow）

GitHub の Additional Product Terms は、GitHub-hosted runner の用途を「workflow が動く repo に紐づくソフトウェアプロジェクト」の production / testing / deployment / publication に限定している。webtunnel の runner で他アプリの dev サーバを動かして動作確認するのはこれに抵触するため、**実アプリで使う時は各アプリ repo で workflow を動かす**（simtunnel と同じ判断）。

- `session.yml` を reusable workflow（`workflow_call`）とし、各アプリ repo からは薄い caller workflow で呼ぶ。webtunnel 自身は `browser-session.yml`（`workflow_dispatch` ラッパー）経由で呼ぶ
- アプリ repo 側に Secrets（`TS_OIDC_CLIENT_ID` / `TS_OIDC_AUDIENCE`）の登録が必要。OIDC token の subject は caller repo 基準になるため、**caller repo の作成時期に応じて subject 形式が変わる**（「セットアップ手順」の immutable ID 形式を参照）。simtunnel の credential を流用できるとは限らない
- 起動するプロジェクトは input で渡す（「dev サーバの起動」参照）。`working_directory` は caller リポジトリルート相対
- caller repo の visibility（public / private）は問わず、preflight でも確認しない。「リポジトリは public で運用する」（「リポジトリ公開に耐える安全性」）は webtunnel リポジトリ自身の方針であり、caller repo の visibility は独立

caller workflow の例（アプリ repo の `.github/workflows/browser-session.yml`）。`local/webtunnel` は `--start-url` / `--no-record` / `--no-preview` を対応する input の `-f` として送り、**caller 側で未宣言の input を送ると dispatch 自体が拒否される**ため、CLI の全オプションを使えるよう任意 input もパススルーで宣言しておく:

```yaml
name: browser-session
# run-name は local/webtunnel CLI が run を特定するキーのためこの形式を維持する
run-name: "session=${{ inputs.session }} duration=${{ inputs.duration_minutes }}m"
on:
  workflow_dispatch: # fork PR に Secrets を渡さないため workflow_dispatch のみ
    # session / duration_minutes は local/webtunnel の up が常に送るため宣言必須
    # （未定義の input を送ると dispatch が拒否される）
    inputs:
      session:
        required: true
        default: dev
      duration_minutes:
        required: true
        default: "60"
      start_url:
        required: false
        default: "" # 空なら dev サーバの URL を開く（session.yml 側の既定に合わせる）
      record:
        required: false
        default: "true"
      preview:
        required: false
        default: "true"
      setup_script:
        required: false
        default: ".webtunnel/setup.sh"
jobs:
  session:
    permissions:
      id-token: write
      contents: read
    uses: bannzai/webtunnel/.github/workflows/session.yml@<commit SHA> # main
    with:
      session: ${{ inputs.session }}
      duration_minutes: ${{ inputs.duration_minutes }}
      start_url: ${{ inputs.start_url }}
      record: ${{ inputs.record }}
      preview: ${{ inputs.preview }}
      setup_script: ${{ inputs.setup_script }}
      # 以下はアプリに合わせて固定値で書く（起動するのは常にこのプロジェクトのため）
      setup_command: npm ci
      start_command: npm run dev
      port: "3000"
      node_version: "22"
      # Chrome 拡張を読み込んで確認する場合だけ指定する（ビルドは setup_command で済ませておく）
      # extension_path: chrome-extension/dist
    secrets:
      TS_OIDC_CLIENT_ID: ${{ secrets.TS_OIDC_CLIENT_ID }}
      TS_OIDC_AUDIENCE: ${{ secrets.TS_OIDC_AUDIENCE }}
      # ログイン済み状態で始める場合のみ（.webtunnel/setup.sh を置いた repo）
      WEBTUNNEL_AUTH_ENV: ${{ secrets.WEBTUNNEL_AUTH_ENV }}
```

ローカル CLI は `WEBTUNNEL_REPO` でアプリ repo に向ける（`WEBTUNNEL_WORKFLOW` は caller workflow のファイル名。既定 `browser-session.yml`）:

```bash
WEBTUNNEL_REPO=<owner>/<repo> local/webtunnel up <session> --wait
```

## リポジトリ構成

```text
webtunnel/
├── PROJECT.md                        # 本ファイル（設計の SSOT）
├── AGENTS.md / CLAUDE.md
├── .github/workflows/
│   ├── session.yml                   # reusable workflow (workflow_call): Chromium セッションの実体
│   └── browser-session.yml           # workflow_dispatch: webtunnel 自身用の薄いラッパー（session.yml を呼ぶ）
├── runner/                           # GHA 側スクリプト
│   ├── start-dev-server.sh           # caller repo の dev サーバ起動 + 応答待ち（ログは artifact）
│   ├── start-chromium.sh             # Xvfb + headed Chromium 起動 + CDP 応答待ち
│   ├── run-auth-setup.sh             # caller repo のセットアップスクリプト実行（ログイン済み状態を作る）
│   ├── start-recording.sh            # ffmpeg x11grab で録画開始（fragmented MP4）
│   ├── stop-recording.sh             # 録画を SIGINT で停止してファイナライズ
│   ├── preview-server.py             # ライブ映像の MJPEG 配信（閲覧ページ + /stream.mjpeg）
│   ├── start-preview.sh              # preview サーバ起動 + listen 待ち
│   ├── bridge.sh                     # socat: tailscale IF → 各ポート（直接到達可能ならスキップ）
│   └── keepalive.sh                  # duration_minutes までジョブを維持（CDP 死活監視付き）
├── examples/
│   └── auth-demo/                    # ログイン必須ページを立てて突破するサンプル兼検証用
│       ├── server.py                 # cookie が無いと中身が見えないデモサーバ
│       └── setup.sh                  # setup_script のサンプル（agent-browser でフォームログイン）
├── webProject/                       # 自己検証用のサンプル Web アプリ（Vite）
├── webExtension/                     # 自己検証用のサンプル Chrome 拡張（Manifest V3・popup のみ）
├── local/
│   └── webtunnel                     # ローカル CLI: up / down / list / status / cdp / preview / screenshot / wait
└── skills/                           # AI エージェント向け skill（Agent Skills 標準）
    ├── install.sh                    # skills/<name>/ をグローバル skill ディレクトリへ symlink 設置
    └── webtunnel/                    # 利用者（AI エージェント）の入口となる skill
```

## セットアップ手順

Tailscale の ACL は simtunnel の Phase 0 で設定済みのものを共用する（`tag:ci` の発信全拒否）。trust credential は後述の理由で webtunnel 専用に発行する。

### OIDC subject は immutable ID 形式になる（重要）

GitHub は 2026-07-15 以降に作成されたリポジトリの OIDC subject claim を **immutable ID 形式**にした。owner 名・repo 名に数値 ID が付き、`include_claim_keys` でカスタマイズしても ID は除去できない（参照: https://github.blog/changelog/2026-04-23-immutable-subject-claims-for-github-actions-oidc-tokens/ ）。

```text
従来（simtunnel 等、2026-07-15 より前に作成）: repo:bannzai/simtunnel:ref:refs/heads/main
immutable（webtunnel 等、それ以降に作成）:     repo:bannzai@<owner-id>/webtunnel@<repo-id>:ref:refs/heads/main
```

このため **simtunnel の credential（subject `repo:bannzai/*`）は webtunnel をカバーできない**。webtunnel 用に別の trust credential を発行する。対象リポジトリの subject 接頭辞は次で取得する:

```bash
gh api /repos/bannzai/webtunnel/actions/oidc/customization/sub --jq '.sub_claim_prefix'
```

### 1. Trust credential の発行（OIDC）

https://login.tailscale.com/admin/settings/trust-credentials

1. **New credential** → credential type で **OpenID Connect** を選択
2. Issuer: **GitHub** / Subject: 上記コマンドが返した接頭辞に `:*` を付けた値
3. Scopes: **Custom scopes** の一覧から **Keys > Auth Keys** の **Write** にチェック → タグは **tag:ci** を選択
4. 発行された **Client ID** と **Audience** を控える（OAuth client と違い secret は存在しない）

### 2. GitHub Secrets への登録

```bash
gh secret set TS_OIDC_CLIENT_ID -R bannzai/webtunnel
gh secret set TS_OIDC_AUDIENCE -R bannzai/webtunnel
```

## 新しいプロジェクトに webtunnel を導入する

アプリ repo 側でやることの一覧。Tailscale の ACL（`tag:ci` の発信全拒否）は設定済みのものを共用するため、追加作業はない。

### 1. subject 接頭辞を確認する

credential の subject 形式は repo の作成時期で変わる（前掲「OIDC subject は immutable ID 形式になる」）。導入先ごとに実物を確認する:

```bash
gh api /repos/<owner>/<repo>/actions/oidc/customization/sub --jq '.sub_claim_prefix'
```

### 2. trust credential を発行して Secrets に登録する

返ってきた接頭辞に `:*` を付けた値を Subject にして credential を発行し（手順は「1. Trust credential の発行（OIDC）」と同じ）、導入先 repo に登録する:

```bash
gh secret set TS_OIDC_CLIENT_ID -R <owner>/<repo>
gh secret set TS_OIDC_AUDIENCE -R <owner>/<repo>
```

既存の credential の subject がその repo をカバーしていれば（ワイルドカードの範囲内なら）発行は不要で、同じ Client ID / Audience をそのまま登録すればよい。

### 3. caller workflow を追加する

`.github/workflows/browser-session.yml` を「各アプリ repo での実行（reusable workflow）」の例をベースに作る。プロジェクトに合わせて変えるのは `setup_command` / `start_command` / `working_directory` / `port` / `node_version` の 5 つ。`uses:` の commit SHA は次で取得する:

```bash
gh api repos/bannzai/webtunnel/commits/main --jq '.sha'
```

### 4. 起動して確認する

```bash
WEBTUNNEL_REPO=<owner>/<repo> local/webtunnel up dev --wait
WEBTUNNEL_REPO=<owner>/<repo> local/webtunnel cdp dev
agent-browser --session "$(basename "$(git rev-parse --show-toplevel)")" \
  --cdp http://<tailscale IP>:9222 snapshot
```

dev サーバが起動しない場合は run のログか artifact `dev-server-log-<session>` を見る。

## セッションのライフサイクル

```text
1. webtunnel up <session>
     └─ gh workflow run browser-session.yml -f session=<session>
2. Runner: dev サーバ起動 → Xvfb + Chromium 起動（dev サーバの URL を開く）→ セットアップ（ログイン）→ 録画開始 → preview 起動
     → tailscale join (hostname=webtunnel-<session>) → socat bridge
3. Local: webtunnel status <session>（= http://<tailscale IP>:9222/json/version）が 200 になったら ready
4. agent-browser --cdp http://<tailscale IP>:9222 で操作。webtunnel preview <session> で画面を見る
5. webtunnel down <session>
     └─ gh run cancel（ephemeral node は自動削除。timeout-minutes が保険）
     └─ always() の step が録画を artifact recording-<session> にアップロード
```

## 検証

- セッション疎通: `local/webtunnel status <session>` が HTTP 200 で Browser / webSocketDebuggerUrl を返すこと
- 操作: `agent-browser --cdp http://<IP>:9222 open https://example.com` → `screenshot ./tmp/xx.png` が撮れること
- preview: `local/webtunnel preview <session>` で開いたページにセッションの画面が表示され、CDP 操作がライブ映像に反映されること
- 録画: セッション終了後、`gh run download <run-id> -R bannzai/webtunnel -n recording-<session>` で mp4 が取得でき再生できること
- dev サーバ: `local/webtunnel up <session> --wait` だけでサンプルアプリ（webProject）が開いた状態になり、`agent-browser --cdp http://<IP>:9222 snapshot` にカウンタ・フォーム・非同期に読み込んだ一覧が日本語で出ること。ボタンをクリックするとカウンタの表示が変わること
- ログイン済み状態: `--setup-script examples/auth-demo/setup.sh` で起動したセッションで、ローカルの agent-browser から `http://127.0.0.1:8123/` を開くとログインフォームではなく保護されたページが見えること
- 認証情報の非露出: 同じ run の `gh run view <run-id> --log` と録画 artifact に、`WEBTUNNEL_AUTH_ENV` に入れたパスワードとログインフォームが現れないこと

## 実装フェーズ

### Phase 1: 疎通（完了: 2026-08-11）

- browser-session.yml / session.yml / runner スクリプト / local CLI
- ローカルの agent-browser から tailnet 越しに CDP 接続し、ページ操作・スクリーンショットが動くこと
- 録画 artifact が down 後に取得できること

#### Phase 1 実測（2026-08-11 / ubuntu-latest / Google Chrome 150.0.7871.128）

| 項目 | 実測 |
|---|---|
| `webtunnel status`（`GET /json/version`） | HTTP 200 / 0.31 秒 |
| `agent-browser --cdp open <url>`（ページ遷移） | 3.3 秒 |
| `agent-browser --cdp screenshot`（1280x800 PNG） | 2.2 秒 |
| セッション ready まで（dispatch からの総時間） | 3 分前後 |
| 録画（1280x800 / 5fps / h264） | 103 秒で 212KB |

- DERP 経由でも CDP の操作レイテンシは実用範囲だった。simtunnel（WDA の `GET /screenshot` が 1 分超）と違い、スクリーンショットの取得経路を別途用意する必要はない
- runner の Chromium には CJK フォントが無く、日本語が豆腐（□）になる。`start-chromium.sh` で `fonts-noto-cjk` を導入して解消した
- `webtunnel down`（`gh run cancel`）後も `if: always()` の step が実行され、録画 artifact を取得できることを確認した

### preview（ライブ映像）（完了: 2026-08-11）

- `runner/preview-server.py` / `start-preview.sh` / `session.yml` の `preview` input（既定 true。`up --no-preview` で preview サーバを起動せず :9100 も bridge しない）/ `local/webtunnel preview <session>`
- ブラウザで開いた preview ページにセッションの画面が表示され、CDP 操作がライブで反映されること

#### preview 実測（2026-08-11 / ubuntu-latest / 1280x800 の Xvfb を x11grab / 表示は日本語 Wikipedia）

ローカルから 30 秒間ストリームを受信し、フレーム数と転送量から算出した値。

| ストリーム設定 | 実測 fps | 帯域 | 1 フレーム平均 |
|---|---|---|---|
| 2fps / 640 幅 / quality 8（既定） | 1.87 fps | 54 KB/s | 29 KB |
| 5fps / 640 幅 / quality 8 | 4.67 fps | 134 KB/s | 28 KB |
| 2fps / 1280 幅 / quality 8 | 1.87 fps | 176 KB/s | 93 KB |
| 5fps / 1280 幅 / quality 8 | 4.10 fps | 382 KB/s | 92 KB |
| 2fps / 640 幅 / quality 4 | 1.87 fps | 80 KB/s | 42 KB |

遅延（CDP でタブを開く / 閉じる操作をしてから、その変化が映ったフレームがローカルに届くまで）は 6 回測って**中央値 1.47 秒**（最小 1.44 / 最大 1.55）。既定の 2fps ではフレーム間隔 0.5 秒がこの値に含まれる。

- **このセッションの tailnet は direct 接続だった**（`tailscale status` が `direct`。DERP relay 経由ではない）。382 KB/s まで出たのはそのため。NAT の条件次第で simtunnel の実測（DERP relay 経由で約 60KB/s）まで落ちうるため、**既定はその帯域でも成立する想定で 2fps / 640 幅 / quality 8（54 KB/s）にした**（relay 経由の実測は未取得。「未検証事項・リスク」参照）。回線が太い時は preview ページのフォームで上げられる
- 実測 fps が指定より 7〜18% 低いのは x11grab と JPEG エンコードのオーバーヘッド。指定 5fps / 1280 幅で最も落ち込む（4.10 fps）
- MJPEG はフレーム間圧縮が無いため、帯域はほぼ「1 フレームのサイズ × fps」になる。解像度を半分にする方が quality を下げるより効く（1280 幅 93KB に対し 640 幅 29KB）

### Phase 2: dev サーバ起動と各アプリ repo への導入手順

- dev サーバ起動の input（`setup_command` / `start_command` / `working_directory` / `port` / `ready_path` / `node_version`）と `runner/start-dev-server.sh`
- ログイン済み状態でのセッション開始（`setup_script` / `WEBTUNNEL_AUTH_ENV`）と `runner/run-auth-setup.sh`・`examples/auth-demo/`
- 自己検証用のサンプル Web アプリ（`webProject/`）と `browser-session.yml` の `sample_app` input
- 「新しいプロジェクトに webtunnel を導入する」の手順

#### Phase 2 実測（2026-08-11 / ubuntu-latest / Vite 8.2.1 / Node 22）

| 項目 | 実測 |
|---|---|
| dispatch → セッション ready | 66 秒 |
| `actions/setup-node`（Node 22） | 1 秒 |
| `npm ci`（Vite のみ / 17 パッケージ） | 2 秒 |
| Vite の起動（listen まで） | 0.23 秒 |
| dev サーバの step 全体（setup + 起動 + ready 判定） | 4 秒 |
| 録画 | 93.8 秒で 152KB（h264 1280x800 5fps） |

- runner の Chromium は 1280x800 のウィンドウだが、ブラウザ UI を除いたビューポートは 1280x656 になる。録画（Xvfb の画面全体）は 1280x800、CDP のスクリーンショットは 1280x656
- `npm ci` の結果はキャッシュしていない。依存の多いプロジェクトでは ready までが伸びる。必要になったら `actions/setup-node` の `cache: npm` を `working_directory` 込みで足す

### Phase 3: 残り

- 実アプリ repo への caller workflow 展開（trust credential の subject 確認と Secrets 登録が repo ごとに要る）
- 録画 / スクリーンショットを PR コメントへ自動添付するフロー（gh-r2-image skill との接続）

## 未検証事項・リスク

- concurrency group は caller リポジトリ単位のため、repo を跨いだ同名セッション（tailnet ホスト名の衝突）は防げない。セッション名にリポジトリ由来の接頭辞を使う運用で回避する
- `cancel-in-progress: false` のため、同名セッションを down せずに再起動すると新しい run は前の run の終了までキューで待つ。作り直す時は先に `webtunnel down` する
- ubuntu-latest のイメージ更新で Chromium のバイナリ名やプリインストール状況が変わる可能性がある。start-chromium.sh は google-chrome → google-chrome-stable → chromium-browser の順でフォールバックする
- preview の実測は direct 接続のセッションでしか取れていない。DERP relay 経由に落ちた時に既定値（54 KB/s）が成立するかは未検証。映像が明らかに遅れる時は `tailscale status` で relay かどうかを確認し、preview ページで fps / 解像度を下げる
