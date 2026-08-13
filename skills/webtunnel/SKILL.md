---
name: webtunnel
description: |
  GitHub Actions の Linux Runner 上で Chromium を起動し、Tailscale 経由でローカルの agent-browser から
  CDP 接続して Web の動作確認を行う skill。ローカルマシンのリソースを使わずにページ操作・スクリーンショット・
  操作過程の録画（artifact）取得ができる。セッションの起動・操作・終了と、使うべきかどうかの判断を扱う。
  ローカルのブラウザで完結する検証は agent-browser skill が担当する（本 skill はリモート実行が要る場合に使う）。
  使用例: "webtunnel でブラウザの動作確認をして" "GHA 上の Chromium でページを開いて" "/webtunnel"
allowed-tools:
  - Bash(bash ${CLAUDE_SKILL_DIR}/scripts/webtunnel-cli.sh:*)
  - Bash(WEBTUNNEL_REPO=* bash ${CLAUDE_SKILL_DIR}/scripts/webtunnel-cli.sh:*)
  - Bash(WEBTUNNEL_WORKFLOW=* bash ${CLAUDE_SKILL_DIR}/scripts/webtunnel-cli.sh:*)
  - Bash(bash ${CLAUDE_SKILL_DIR}/scripts/preflight.sh:*)
  - Bash(bash ${CLAUDE_SKILL_DIR}/scripts/fetch-recording.sh:*)
  - Bash(WEBTUNNEL_REPO=* bash ${CLAUDE_SKILL_DIR}/scripts/fetch-recording.sh:*)
  - Bash(bash ${CLAUDE_SKILL_DIR}/scripts/test/test-webtunnel-cli.sh:*)
  - Bash(bash ${CLAUDE_SKILL_DIR}/scripts/test/test-preflight.sh:*)
  - Bash(bash ${CLAUDE_SKILL_DIR}/scripts/test/test-fetch-recording.sh:*)
  - Bash(agent-browser:*)
  - Bash(gh run list:*)
  - Bash(gh run view:*)
  - Bash(gh run download:*)
  - Read
  - Glob
---

# webtunnel

GitHub Actions の Linux Runner 上の Chromium を、Tailscale 経由でローカルの agent-browser から CDP（Chrome DevTools Protocol）で操作する。ローカルブラウザで完結する検証は `agent-browser` skill が担当し、本 skill は**リモート実行が要る場合**を担当する。

設計・セットアップ手順・実測値の SSOT は、本 skill と同じリポジトリの `PROJECT.md`。場所は `bash ${CLAUDE_SKILL_DIR}/scripts/webtunnel-cli.sh --path` が出力する `<リポジトリルート>/local/webtunnel` から辿り、その `<リポジトリルート>/PROJECT.md` を Read する。

## 重要な原則

- **CDP への接続は tailscale IP で行う。** Chromium は Host ヘッダが IP か localhost 以外のリクエストを拒否するため、MagicDNS 名（`webtunnel-<session>`）では接続できない。IP は `webtunnel-cli.sh cdp <session>` が出力する。
- **画面の状態は実スクリーンショットを Read して判断する。** workflow のログや `status` の HTTP 200 だけで「表示できている」と判断しない。
- **runner から到達できる URL しか開けない。** ローカルマシンで動いている dev サーバは runner の Chromium からは見えない。
- セッションは使う時だけ up し、終わったら down する（放置しても `duration_minutes`（既定 60 分）で自動終了する）。
- **Codex CLI から実行する場合は `${CLAUDE_SKILL_DIR}` を `~/.agents/skills/webtunnel` に読み替える。** この記法を skill ディレクトリへ置換するのは Claude Code だけで、Codex CLI では空に展開されてコマンドが失敗する。

## ファイル構成

- `scripts/webtunnel-cli.sh` — `local/webtunnel` CLI を、skill の設置場所（symlink 経由を含む）に依存せず呼び出すラッパー
- `scripts/preflight.sh` — Phase 1 の判断材料（CLI・agent-browser・tailnet 接続・リポジトリの公開設定・caller workflow・Secrets）を集めて READY / NOT_READY を返す
- `scripts/fetch-recording.sh` — セッション名から workflow run を特定して録画 artifact をダウンロードする
- `scripts/test/test-webtunnel-cli.sh` / `test-preflight.sh` / `test-fetch-recording.sh` — 各スクリプトの検証

## ワークフロー

### Phase 1: 使うべきか判断する

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/preflight.sh <owner>/<repo>
```

READY なら Phase 2 へ進む。NOT_READY は出力された対処を実施してから再実行する（読み取りのみで冪等）。

READY でも、次に当たる場合はローカルの `agent-browser` skill に倒す:

- 即時性が最優先（webtunnel はセッションが ready になるまで数分かかる。ローカルブラウザは即時。所要時間の実測値は PROJECT.md「Phase 1 実測」を参照）
- 開く対象がローカルでしか動いていない（runner の Chromium から localhost は runner 自身を指す）
- 未公開の機能を扱う（public repo では Actions のログと artifact が公開される）

逆に次のいずれかに当たるなら webtunnel を選ぶ:

- ローカルマシンの CPU・メモリを消費したくない
- 操作の過程を録画して PR にエビデンスとして残したい
- ローカルに検証対象の環境が無い

#### caller workflow の整備

対象 repo に `.github/workflows/browser-session.yml` が無い場合は、PROJECT.md「各アプリ repo での実行（reusable workflow）」の caller workflow を追加する。Secrets（`TS_OIDC_CLIENT_ID` / `TS_OIDC_AUDIENCE`）の登録と、リポジトリの作成時期によって変わる OIDC subject の形式も同 PROJECT.md を参照する。

### Phase 2: セッションを起動する

セッション名は repo・worktree を識別できる一意な名前にする（repo を跨いで同名だと tailnet ホスト名 `webtunnel-<session>` が衝突する）。

```bash
WEBTUNNEL_REPO=<owner>/<repo> bash ${CLAUDE_SKILL_DIR}/scripts/webtunnel-cli.sh up <session> --wait
```

`--wait` は CDP がローカルから応答するまで待つ。特定ブランチのコードで動かす `--ref`、最初に開く URL を指定する `--start-url` などのオプションは `local/webtunnel` の冒頭コメントを参照する（`WEBTUNNEL_REPO` を省略すると webtunnel リポジトリ自身が対象になる）。`--start-url` / `--no-record` は caller workflow が `start_url` / `record` input を宣言している場合だけ渡せる（宣言の無い input を送ると dispatch 自体が拒否される。PROJECT.md の caller 例は宣言済み）。

#### ログインが必要なページを扱う

対応方法は次の優先順位で選ぶ:

1. **サービス側の dev 限定の工夫（secret 不要）**: dev 環境の匿名認証・自動ログイン・dev DB にしか存在しないテストアカウント等で、ログインの壁自体を無くす
2. **ローカルからの storage state 注入（Actions に secret を置かない）**: セッション ready 後に `agent-browser --cdp http://<tailscale IP>:9222 --state <state.json> open <url>` で、ローカルで一度ログインして保存した認証済み状態をリモートの Chromium に持ち込む（`--cdp` を付けないとローカルのブラウザに注入してしまう）
3. **secret `WEBTUNNEL_AUTH_ENV` + セットアップスクリプト**: セッション開始時に runner 上で自動ログインする。前の 2 つが使えない場合（変えられない外部サービス、ログインフロー自体の検証）の汎用経路。設計・secret の作り方・スクリプトの置き場所は PROJECT.md「ログイン済み状態でのセッション開始」を参照する

バックエンド構成ごとの目安:

- **認証ビルトインの BaaS（Firebase / Supabase 等）**: dev プロジェクトを分離し、匿名認証か seed 済みテストユーザーで 1 に倒す。webtunnel の都合で本番プロジェクトの匿名認証を新たに有効化しない（API キーは公開情報のため、作り捨てアカウントで無料枠・コストを悪用される面が開く。有効化は App Check / CAPTCHA・レート制限・匿名アカウントの定期削除とセットで判断する）
- **認証をアプリ層で自作している構成（Turso / SQLite / PostgreSQL 等の DB 単体）**: dev サーバを runner 上で起動し（`setup_command` / `start_command`。PROJECT.md「dev サーバの起動」参照）、ローカル DB ファイルや seed 済み dev DB で完結させる。DB 接続情報が要る場合だけ dev 専用の値を 3 の secret で渡す（`WEBTUNNEL_AUTH_ENV` はログイン資格情報に限らず、セットアップに必要な秘匿値全般を運ぶ封筒として使える）

どの方式でも守ること:

- **dev 限定の仕掛けを本番に漏らさない**: 自動ログイン・テストアカウントは環境変数・ビルドフラグで dev 環境だけ有効にし、本番ビルド・本番 DB には入れない。アプリ側 repo が public ならその工夫のコード自体も公開されるため、知られても無害な設計（dev 環境にしか存在しないアカウント等）にする
- 本番の全権キー（service_role・本番 DB トークン等）や本番・個人アカウントの資格情報を、webtunnel の経路（secret・セットアップスクリプト・録画に写る画面）に載せない
- **録画 artifact は公開ダウンロードされる前提で `--no-record` を判断する**: セッション中に手動でログイン操作を行う場合（ログインフロー自体の検証、storage state 注入後の再ログイン等）は入力中の画面が録画に写るため `up <session> --no-record` を必須にする。セットアップスクリプト経由のログインは録画開始前に終わるが、ログイン後の画面に公開できない内容が出るなら同じく `--no-record` にする（PROJECT.md「リポジトリ公開に耐える安全性」の「録画 artifact は公開される前提で使う」参照）

### Phase 3: 操作する

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/webtunnel-cli.sh cdp <session>
```

が CDP の URL（`http://<tailscale IP>:9222`）を出力する。以降は agent-browser を `--cdp` で接続して操作する。

```bash
export AGENT_BROWSER_SESSION="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")-wt-<session>"
agent-browser --cdp http://<tailscale IP>:9222 open https://example.com
agent-browser --cdp http://<tailscale IP>:9222 snapshot -i
agent-browser --cdp http://<tailscale IP>:9222 screenshot ./tmp/after.png
```

- 操作コマンドの一覧は `agent-browser` skill を参照する
- セッション名の命名規則は `~/.claude/rules/agent-browser-session-naming.md` に従う
- スクリーンショットだけなら `webtunnel-cli.sh screenshot <session> <出力パス>` でも撮れる。撮ったら Read で画面を見てから結論を出す

### Phase 4: 終了して録画を取得する

```bash
WEBTUNNEL_REPO=<owner>/<repo> bash ${CLAUDE_SKILL_DIR}/scripts/webtunnel-cli.sh down <session>
WEBTUNNEL_REPO=<owner>/<repo> bash ${CLAUDE_SKILL_DIR}/scripts/fetch-recording.sh <session> ./tmp
```

`WEBTUNNEL_REPO` は Phase 2 の起動時と同じ値を指定する（省略すると webtunnel リポジトリ自身を探しに行き、対象の run を見つけられない）。`down` は run をキャンセルする（ephemeral node は tailnet から自動削除される）。録画は `if: always()` の step が artifact `recording-<session>` へアップロードするため、down の後に `fetch-recording.sh` で取得できる。PR に画像・動画を貼る場合は `gh-r2-image` skill を使う。

## 制約・ハマりどころ

- run を作り直すと tailscale IP が変わる。繋がらなくなったら `cdp` で引き直す
- 同名セッションを down せずに再 up すると、新しい run は前の run の終了までキューで待つ。作り直す時は先に down する
- public repo では Actions のログと artifact（録画・スクリーンショット）が公開される

## エラーハンドリング

- `up` が「すでに起動中」と返す → `webtunnel-cli.sh list` で tailnet と run の状態を確認し、不要な run を down する
- `status` が応答しない（tailnet にホストが無い）→ セットアップ中か run の失敗。`gh run view <run-id> --log-failed -R <owner>/<repo>` でログを確認する
- CDP には繋がるがページが表示されない → screenshot を Read して確認し、runner から到達できない URL を開いていないか確認する
- `fetch-recording.sh` が「まだ実行中」と返す → 録画はセッション終了時にアップロードされるため、`down` の後に再実行する

## 検証方法

1. `bash ${CLAUDE_SKILL_DIR}/scripts/test/test-webtunnel-cli.sh` を実行し、CLI の解決（環境変数指定・リポジトリ内・symlink 経由）と異常系が全 PASS することを確認する。
2. `bash ${CLAUDE_SKILL_DIR}/scripts/test/test-preflight.sh` と `bash ${CLAUDE_SKILL_DIR}/scripts/test/test-fetch-recording.sh` を実行し、READY / NOT_READY の判定と run 特定の分岐が全 PASS することを確認する。
3. 実セッションでの疎通確認: `preflight.sh bannzai/webtunnel` が READY を返す → `webtunnel-cli.sh up <session> --wait` → `webtunnel-cli.sh status <session>` が HTTP 200 を返す → `agent-browser --cdp <URL> open <url>` と `screenshot` で PNG を取得し Read で描画されていることを確認 → `webtunnel-cli.sh down <session>` → `fetch-recording.sh <session> ./tmp` で mp4 を取得できることを確認する。
