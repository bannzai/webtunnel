# webtunnel

GitHub Actions の Linux Runner 上で Chromium を起動し、Tailscale 経由でローカルの agent-browser から操作・動作確認を行うためのツール群。[simtunnel](https://github.com/bannzai/simtunnel)（iOS Simulator 版）の Web 版。

## 目的

- ローカルマシンのリソースを消費せずに、ブラウザでの動作確認を GHA runner 上で行う
- agent-browser の CDP 接続（`--cdp`）で、tailnet 越しに runner 上の Chromium を操作する
- 動作確認の過程（録画）を artifact として PR に残す

## 使い方

```bash
# セッション起動（CDP が応答するまで待つ）
local/webtunnel up dev --wait

# 接続情報（tailscale IP ベースの CDP URL）を表示
local/webtunnel cdp dev

# agent-browser で操作（--session は作業スペース名にする）
agent-browser --session "$(basename "$(git rev-parse --show-toplevel)")" \
  --cdp http://<tailscale IP>:9222 open https://example.com

# スクリーンショット
local/webtunnel screenshot dev ./tmp/check.png

# 終了（録画が artifact recording-<session> に残る）
local/webtunnel down dev
```

ログインが必要なページを触る場合は、caller repo に `.webtunnel/setup.sh` を置く（`--setup-script` でパス変更可）。Chromium 起動後・録画開始前に実行されるため、ログイン操作は録画に写らない。資格情報は secret `WEBTUNNEL_AUTH_ENV`（`KEY=VALUE` を base64 で単一行にしたもの）で渡す。サンプルは `examples/auth-demo/`、設計は PROJECT.md「ログイン済み状態でのセッション開始」を参照。

CDP は Host ヘッダの制約で MagicDNS 名では接続できないため、接続は tailscale IP で行う（詳細と設計全体は PROJECT.md 参照）。

## Status

Phase 1（疎通）実装済み。設計の SSOT は PROJECT.md。

## 経緯

- 構想の起点: https://github.com/bannzai/castle/issues/403
- セキュリティ設計・規約対応の参考（横展開元）: https://github.com/bannzai/simtunnel の PROJECT.md「リポジトリ公開に耐える安全性」
