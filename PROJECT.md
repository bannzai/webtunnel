# WebTunnel

GitHub Actions の Linux Runner 上で Chromium を起動し、Tailscale 経由でローカルの agent-browser から CDP（Chrome DevTools Protocol）で操作・動作確認するためのツール群。[simtunnel](https://github.com/bannzai/simtunnel)（iOS Simulator 版）の Web 版であり、セキュリティ設計は simtunnel の PROJECT.md「リポジトリ公開に耐える安全性」を横展開している。

本ファイルが設計の SSOT。設計に関わる変更をしたら同じ変更で本ファイルも更新する。

## 目的

- ローカルマシンのリソースを消費せずに、ブラウザでの動作確認を GHA runner 上で行う
- agent-browser の CDP 接続（`--cdp`）で、tailnet 越しに runner 上の Chromium を操作する
- 動作確認の過程（録画）を artifact として残し、PR に添付できるようにする

## アーキテクチャ

```text
ローカル (macOS)                         GitHub Actions (ubuntu-latest)
┌──────────────────────┐                ┌──────────────────────────────────┐
│ local/webtunnel CLI  │ gh workflow run │ browser-session.yml (dispatch)   │
│ agent-browser --cdp ─┼───┐            │  └─ session.yml (reusable)       │
└──────────────────────┘   │            │      dev サーバ 127.0.0.1:5173   │
                           │  tailnet   │      Xvfb :99 (1280x800)         │
                           │            │      └─ Chromium (headed)        │
                           │            │          開く先 localhost:5173   │
                           │            │          CDP 127.0.0.1:9222      │
                           └────────────┼──→ socat: TS_IP:9222 → 127.0.0.1 │
                             (Tailscale)│      ffmpeg x11grab → artifact   │
                                        └──────────────────────────────────┘
```

- runner は ephemeral node として tailnet に参加し、ホスト名は `webtunnel-<session>` になる
- CDP はローカルの 127.0.0.1:9222 で待ち受け、socat で tailscale インターフェースへ中継する
- dev サーバは runner の localhost だけで動かし、tailnet には出さない（見るのは同じ runner 上の Chromium のため）
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

- **ポートは `PORT` 環境変数として両コマンドへ渡す**。`port` input を SSOT にして、コマンド文字列側にポート番号を重複させない。Next.js / Nuxt / CRA は `PORT` をそのまま解釈し、Vite は `vite.config.js` で `process.env.PORT` を読む
- **ready 判定は `http://127.0.0.1:<port><ready_path>` への到達**とし、HTTP ステータスは問わない（応答がある = listen している）。dev サーバのプロセスが死んだら待たずに即失敗させ、ログ末尾を step の出力に出す
- **ツールチェーン準備は session.yml 側**に持つ。reusable workflow の呼び出しは job 単位で、caller は job の中に step を差し込めないため。Node 以外（Python / Ruby / Go 等）は ubuntu-latest のプリインストール版を `setup_command` から使う
- **ビルド成果物を artifact 経由で受け取る経路（simtunnel の `app_artifact` 相当）は作らない**。simtunnel でこれが要るのは、macOS runner が高価でビルドを別 job に切り出す動機があり、かつ Flutter 等が `xcodebuild` 直叩きで表現できないため。Web は `setup_command` に任意のシェルコマンドを書けて Linux runner も安価なため、同一 job でビルドすれば足りる。必要になったら caller 側の build job + `download-artifact` を足す
- `start_url` を省略した時は `http://localhost:<port>/` を開く。dev サーバを起動しない場合だけ `about:blank` になる
- dev サーバのログ（`setup_command` の分と起動後の分）は artifact `dev-server-log-<session>` に残す。セッション中のランタイムエラーも down 後に追える

### 自己検証用のサンプル Web アプリ（webProject）

`webProject/` に Vite の最小サンプルアプリを置き、`browser-session.yml` の `sample_app`（既定 `true`）でこれを dev サーバとして起動する。simtunnel の `iOSProject/` + `sample_app` と同じ位置づけで、外部サイトに依存せず webtunnel 単体で「起動 → 操作」まで検証できる。

- 動作確認で意味を持つ要素を 1 ページに置く: クリックで変わるカウンタ、フォーム入力、日本語テキスト（CJK フォント確認）、非同期に更新される要素（`public/items.json` の fetch と経過秒数）
- 1280x800（runner の Chromium のウィンドウサイズ）でスクロールせずに全要素が入るレイアウトにする。録画・スクリーンショットに全要素が写るため
- 依存は Vite のみ。dev サーバ起動の input（`setup_command` = `npm ci` / `start_command` = `npm run dev` / `node_version`）を実際に通す検証対象を兼ねる

### リポジトリ公開に耐える安全性

リポジトリは public で運用する（Linux runner 無料）。tailnet 内の実 IP 等の環境固有情報はこのリポジトリに書かない。simtunnel の PROJECT.md「リポジトリ公開に耐える安全性」と同一の原則を適用する:

1. **公開エンドポイントゼロ**: CDP は tailnet 内からしか到達できない
2. **トリガーは `workflow_dispatch` のみ**: 起動できるのは write 権限者だけ。fork からの PR には Secrets / OIDC トークンの権限が渡らない
3. **長期シークレットを持たない（OIDC / workload identity federation）**: Tailscale への認証は、GitHub が workflow に発行する短命の OIDC トークンで行う。subject が credential に登録した値に一致する workflow しか認証できず、盗まれて困る静的シークレットがそもそも存在しない（Secrets の `TS_OIDC_CLIENT_ID` / `TS_OIDC_AUDIENCE` は識別子であり秘密情報ではない）
4. **Tailscale ACL で双方向を絞る**: `tag:ci` からの発信は全拒否（simtunnel セットアップ時に設定済みのポリシーをそのまま使う。webtunnel 固有の追加設定は不要）
5. **ACL 設定 → runner 参加の順序は入れ替え不可**: simtunnel の Phase 0 で設定済みのため webtunnel では新規作業なし
6. **ephemeral node**: ジョブ終了と同時に tailnet から自動削除される。また workflow は CDP がローカルで応答してから tailnet に参加する（tailnet 内にいる時間を最小化）
7. **`timeout-minutes` でセッション上限**: 消し忘れても最大 6 時間で必ず落ちる
8. **サードパーティ action は commit SHA で固定**: `uses:` はフルレングスの commit SHA + バージョンコメントで固定する。バージョン更新時は `gh api repos/<owner>/<repo>/git/ref/tags/<tag>` で SHA を確認して書き換える
9. **runner スクリプトは workflow と同一 commit に固定**: reusable workflow（session.yml）は runner スクリプトを `job.workflow_repository` / `job.workflow_sha` で checkout する。caller が `uses:` を SHA 固定していれば、実行されるスクリプトも同じ SHA に固定される

### 各アプリ repo での実行（reusable workflow）

GitHub の Additional Product Terms は、GitHub-hosted runner の用途を「workflow が動く repo に紐づくソフトウェアプロジェクト」の production / testing / deployment / publication に限定している。webtunnel の runner で他アプリの dev サーバを動かして動作確認するのはこれに抵触するため、**実アプリで使う時は各アプリ repo で workflow を動かす**（simtunnel と同じ判断）。

- `session.yml` を reusable workflow（`workflow_call`）とし、各アプリ repo からは薄い caller workflow で呼ぶ。webtunnel 自身は `browser-session.yml`（`workflow_dispatch` ラッパー）経由で呼ぶ
- アプリ repo 側に Secrets（`TS_OIDC_CLIENT_ID` / `TS_OIDC_AUDIENCE`）の登録が必要。OIDC token の subject は caller repo 基準になるため、**caller repo の作成時期に応じて subject 形式が変わる**（「セットアップ手順」の immutable ID 形式を参照）。simtunnel の credential を流用できるとは限らない
- 起動するプロジェクトは input で渡す（「dev サーバの起動」参照）。`working_directory` は caller リポジトリルート相対

caller workflow の例（アプリ repo の `.github/workflows/browser-session.yml`）:

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
jobs:
  session:
    permissions:
      id-token: write
      contents: read
    uses: bannzai/webtunnel/.github/workflows/session.yml@<commit SHA> # main
    with:
      session: ${{ inputs.session }}
      duration_minutes: ${{ inputs.duration_minutes }}
      # 以下はアプリに合わせて固定値で書く（起動するのは常にこのプロジェクトのため）
      setup_command: npm ci
      start_command: npm run dev
      port: "3000"
      node_version: "22"
    secrets:
      TS_OIDC_CLIENT_ID: ${{ secrets.TS_OIDC_CLIENT_ID }}
      TS_OIDC_AUDIENCE: ${{ secrets.TS_OIDC_AUDIENCE }}
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
│   ├── start-recording.sh            # ffmpeg x11grab で録画開始（fragmented MP4）
│   ├── stop-recording.sh             # 録画を SIGINT で停止してファイナライズ
│   ├── bridge.sh                     # socat: tailscale IF → CDP ポート（直接到達可能ならスキップ）
│   └── keepalive.sh                  # duration_minutes までジョブを維持（CDP 死活監視付き）
├── webProject/                       # 自己検証用のサンプル Web アプリ（Vite）
└── local/
    └── webtunnel                     # ローカル CLI: up / down / list / status / cdp / screenshot / wait
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
2. Runner: dev サーバ起動 → Xvfb + Chromium 起動（dev サーバの URL を開く）→ 録画開始
     → tailscale join (hostname=webtunnel-<session>) → socat bridge
3. Local: webtunnel status <session>（= http://<tailscale IP>:9222/json/version）が 200 になったら ready
4. agent-browser --cdp http://<tailscale IP>:9222 で操作
5. webtunnel down <session>
     └─ gh run cancel（ephemeral node は自動削除。timeout-minutes が保険）
     └─ always() の step が録画を artifact recording-<session> にアップロード
```

## 検証

- セッション疎通: `local/webtunnel status <session>` が HTTP 200 で Browser / webSocketDebuggerUrl を返すこと
- 操作: `agent-browser --cdp http://<IP>:9222 open https://example.com` → `screenshot ./tmp/xx.png` が撮れること
- 録画: セッション終了後、`gh run download <run-id> -R bannzai/webtunnel -n recording-<session>` で mp4 が取得でき再生できること
- dev サーバ: `local/webtunnel up <session> --wait` だけでサンプルアプリ（webProject）が開いた状態になり、`agent-browser --cdp http://<IP>:9222 snapshot` にカウンタ・フォーム・非同期に読み込んだ一覧が日本語で出ること。ボタンをクリックするとカウンタの表示が変わること

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

### Phase 2: dev サーバ起動と各アプリ repo への導入手順

- dev サーバ起動の input（`setup_command` / `start_command` / `working_directory` / `port` / `ready_path` / `node_version`）と `runner/start-dev-server.sh`
- 自己検証用のサンプル Web アプリ（`webProject/`）と `browser-session.yml` の `sample_app` input
- 「新しいプロジェクトに webtunnel を導入する」の手順

### Phase 3: 残り

- 実アプリ repo への caller workflow 展開（trust credential の subject 確認と Secrets 登録が repo ごとに要る）
- 録画 / スクリーンショットを PR コメントへ自動添付するフロー（gh-r2-image skill との接続）

## 未検証事項・リスク

- concurrency group は caller リポジトリ単位のため、repo を跨いだ同名セッション（tailnet ホスト名の衝突）は防げない。セッション名にリポジトリ由来の接頭辞を使う運用で回避する
- `cancel-in-progress: false` のため、同名セッションを down せずに再起動すると新しい run は前の run の終了までキューで待つ。作り直す時は先に `webtunnel down` する
- ubuntu-latest のイメージ更新で Chromium のバイナリ名やプリインストール状況が変わる可能性がある。start-chromium.sh は google-chrome → google-chrome-stable → chromium-browser の順でフォールバックする
