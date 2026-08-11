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

設計・セットアップ手順・実測値の SSOT は、本 skill と同じリポジトリの `PROJECT.md`（`~/ghq/github.com/bannzai/webtunnel/PROJECT.md`）。

## 重要な原則

- **CDP への接続は tailscale IP で行う。** Chromium は Host ヘッダが IP か localhost 以外のリクエストを拒否するため、MagicDNS 名（`webtunnel-<session>`）では接続できない。IP は `webtunnel-cli.sh cdp <session>` が出力する。
- **画面の状態は実スクリーンショットを Read して判断する。** workflow のログや `status` の HTTP 200 だけで「表示できている」と判断しない。
- **runner から到達できる URL しか開けない。** ローカルマシンで動いている dev サーバは runner の Chromium からは見えない。
- セッションは使う時だけ up し、終わったら down する（放置しても `duration_minutes`（既定 60 分）で自動終了する）。

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

`--wait` は CDP がローカルから応答するまで待つ。特定ブランチのコードで動かす `--ref`、最初に開く URL を指定する `--start-url` などのオプションは `local/webtunnel` の冒頭コメントを参照する（`WEBTUNNEL_REPO` を省略すると webtunnel リポジトリ自身が対象になる）。

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
bash ${CLAUDE_SKILL_DIR}/scripts/webtunnel-cli.sh down <session>
bash ${CLAUDE_SKILL_DIR}/scripts/fetch-recording.sh <session> ./tmp
```

`down` は run をキャンセルする（ephemeral node は tailnet から自動削除される）。録画は `if: always()` の step が artifact `recording-<session>` へアップロードするため、down の後に `fetch-recording.sh` で取得できる。PR に画像・動画を貼る場合は `gh-r2-image` skill を使う。

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
