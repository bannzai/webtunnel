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
└──────────────────────┘   │            │      Xvfb :99 (1280x800)         │
                           │  tailnet   │      └─ Chromium (headed)        │
                           │            │          CDP 127.0.0.1:9222      │
                           └────────────┼──→ socat: TS_IP:9222 → 127.0.0.1 │
                             (Tailscale)│      ffmpeg x11grab → artifact   │
                                        └──────────────────────────────────┘
```

- runner は ephemeral node として tailnet に参加し、ホスト名は `webtunnel-<session>` になる
- CDP はローカルの 127.0.0.1:9222 で待ち受け、socat で tailscale インターフェースへ中継する
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

### 利用者向け skill はこのリポジトリに置き、symlink で設置する

simtunnel の skill（`macos-simtunnel` / `ios-simulator`）は dotfile リポジトリ（bannzai/castle）に実体を置いているが、webtunnel の skill は**本リポジトリの `skills/` に実体を置く**。CLI（`local/webtunnel`）・workflow・runner スクリプトと同じ変更で skill を更新でき、実装と入口がずれないため。

- グローバルへの設置は `skills/install.sh` による symlink（`~/.claude/skills` / `~/.agents/skills` / `~/.codex/skills` のうち存在するもの）。dotfile リポジトリ側にはリンクだけが残る
- skill から CLI を呼ぶ経路は `skills/webtunnel/scripts/webtunnel-cli.sh` に集約する。自身の実体パスからリポジトリルートを辿るため、clone 先や symlink 経由の設置に依存しない
- ローカルブラウザとリモート（webtunnel）の使い分けは `agent-browser` skill から webtunnel skill へ誘導する（判断基準の SSOT は webtunnel skill の Phase 1）

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
- caller repo 上で dev サーバをビルド・起動してから session.yml を呼ぶ形（simtunnel の `build_project` に相当する input）は Phase 2 で設計する（「実装フェーズ」参照）

caller workflow の例（アプリ repo の `.github/workflows/browser-session.yml`）:

```yaml
name: browser-session
run-name: "session=${{ inputs.session }} duration=${{ inputs.duration_minutes }}m"
on:
  workflow_dispatch:
    inputs:
      session:
        required: true
        default: dev
      duration_minutes:
        required: true
        default: "60"
      start_url:
        required: false
        default: "about:blank"
      record:
        required: false
        default: "true"
jobs:
  session:
    permissions:
      id-token: write
      contents: read
    uses: bannzai/webtunnel/.github/workflows/session.yml@<commit SHA> # vX.Y.Z 相当のコメント
    with:
      session: ${{ inputs.session }}
      duration_minutes: ${{ inputs.duration_minutes }}
      start_url: ${{ inputs.start_url }}
      record: ${{ inputs.record }}
    secrets:
      TS_OIDC_CLIENT_ID: ${{ secrets.TS_OIDC_CLIENT_ID }}
      TS_OIDC_AUDIENCE: ${{ secrets.TS_OIDC_AUDIENCE }}
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
│   ├── start-chromium.sh             # Xvfb + headed Chromium 起動 + CDP 応答待ち
│   ├── start-recording.sh            # ffmpeg x11grab で録画開始（fragmented MP4）
│   ├── stop-recording.sh             # 録画を SIGINT で停止してファイナライズ
│   ├── bridge.sh                     # socat: tailscale IF → CDP ポート（直接到達可能ならスキップ）
│   └── keepalive.sh                  # duration_minutes までジョブを維持（CDP 死活監視付き）
├── local/
│   └── webtunnel                     # ローカル CLI: up / down / list / status / cdp / screenshot / wait
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

Phase 2 で各アプリ repo に展開する時も、そのリポジトリの作成時期によって subject 形式が変わる。展開先ごとに `sub_claim_prefix` を確認してから credential の subject を決める。

## セッションのライフサイクル

```text
1. webtunnel up <session>
     └─ gh workflow run browser-session.yml -f session=<session>
2. Runner: Xvfb + Chromium 起動 → 録画開始 → tailscale join (hostname=webtunnel-<session>) → socat bridge
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

### Phase 2: 各アプリ repo への展開

- caller repo の dev サーバ起動（`setup_command` 相当の input）の設計。dev サーバは runner の localhost で動かし、Chromium からは `http://localhost:<port>` で開く
- 録画 / スクリーンショットを PR コメントへ自動添付するフロー（gh-r2-image skill との接続）

## 未検証事項・リスク

- concurrency group は caller リポジトリ単位のため、repo を跨いだ同名セッション（tailnet ホスト名の衝突）は防げない。セッション名にリポジトリ由来の接頭辞を使う運用で回避する
- `cancel-in-progress: false` のため、同名セッションを down せずに再起動すると新しい run は前の run の終了までキューで待つ。作り直す時は先に `webtunnel down` する
- ubuntu-latest のイメージ更新で Chromium のバイナリ名やプリインストール状況が変わる可能性がある。start-chromium.sh は google-chrome → google-chrome-stable → chromium-browser の順でフォールバックする
