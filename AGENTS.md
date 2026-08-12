# webtunnel

GitHub Actions の Linux Runner 上で Chromium を起動し、Tailscale 経由でローカルの agent-browser から CDP で操作・動作確認するためのツール群。

## ドキュメント
- 設計・採用理由・実装フェーズの SSOT は PROJECT.md。設計に関わる変更をしたら同じ変更で PROJECT.md も更新する

## 前提
- public リポジトリで運用する（Linux Runner 無料）。tailnet 内の実 IP 等の環境固有情報を書かない（参照: PROJECT.md「リポジトリ公開に耐える安全性」）
- Tailscale への認証は OIDC（workload identity federation）。GitHub Secrets は `TS_OIDC_CLIENT_ID` / `TS_OIDC_AUDIENCE`（識別子であり長期シークレットではない。simtunnel と同一の値）
- ログイン済み状態でセッションを始める場合のみ、secret `WEBTUNNEL_AUTH_ENV`（開発環境用アカウントの資格情報）を追加で使う（参照: PROJECT.md「ログイン済み状態でのセッション開始」）
- CDP と preview は無認証のため、到達経路は tailnet 内に限定する。公開トンネル（cloudflared / ngrok 等）へ変更する場合は PROJECT.md「リポジトリ公開に耐える安全性」の再検討とセットで行う
- workflow のトリガーは `workflow_dispatch` のみとする（fork PR に Secrets を渡さないため）
- CDP への接続は MagicDNS 名ではなく tailscale IP で行う（参照: PROJECT.md「CDP の Host ヘッダ制約」）

## セッション操作
- `local/webtunnel` CLI を使う: `up <session> [--wait]` / `down <session>` / `list` / `status <session>` / `cdp <session>` / `preview <session>` / `screenshot <session>`（オプションはスクリプト冒頭の使い方を参照）
- 放置しても `duration_minutes`（既定 60 分）で自動終了する
- 動作確認の対象は runner 上で起動する dev サーバ。何をどう起動するかは caller workflow の input で渡す（参照: PROJECT.md「dev サーバの起動」）

## 検証
- セッション疎通: `local/webtunnel status <session>` が HTTP 200 を返すこと
- 操作: `agent-browser --cdp http://<tailscale IP>:9222` で open / screenshot が動くこと（`--session` は作業スペース名にする）
- preview: `local/webtunnel preview <session>` で開いた画面に CDP 操作がライブ映像として反映されること
- 録画: セッション終了後に artifact `recording-<session>` から mp4 が取得できること
- dev サーバ: `up <session> --wait` だけでサンプルアプリ（`webProject/`）が開き、agent-browser でボタンをクリックすると表示が変わること
