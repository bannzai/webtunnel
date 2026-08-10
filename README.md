# webtunnel

GitHub Actions の Linux Runner 上で Chromium を起動し、Tailscale 経由でローカルの agent-browser から操作・動作確認を行うためのツール群。[simtunnel](https://github.com/bannzai/simtunnel)（iOS Simulator 版）の Web 版。

## 目的

- ローカルマシンのリソースを消費せずに、ブラウザでの動作確認を GHA runner 上で行う
- agent-browser の CDP 接続（`--cdp`）で、tailnet 越しに runner 上の Chromium を操作する想定（要検証）
- 動作確認の過程（スクリーンショット・録画）を artifact として PR に残す

## Status

構想段階。設計・実装は未着手。

## 経緯

- 構想の起点: https://github.com/bannzai/castle/issues/403
- セキュリティ設計・規約対応の参考（横展開元）: https://github.com/bannzai/simtunnel の PROJECT.md「リポジトリ公開に耐える安全性」
