#!/usr/bin/env bash
# webtunnel セッションの録画 artifact（recording-<session>）をダウンロードする。
# セッション名から最新の workflow run を引き当てるため、run ID を手で探さなくてよい。
#
# Usage: fetch-recording.sh <session> [出力ディレクトリ]
# Env:   WEBTUNNEL_REPO      対象リポジトリ（既定 bannzai/webtunnel。local/webtunnel と同じ環境変数）
#        WEBTUNNEL_WORKFLOW  caller workflow のファイル名（既定 browser-session.yml）
# Exit:  0=取得成功 / 1=取得できない / 2=引数不正
#
# 同じ引数で再実行すると同じ artifact を同じ場所へ展開し直す（gh run download が上書きする）ため冪等。
set -euo pipefail

REPO="${WEBTUNNEL_REPO:-bannzai/webtunnel}"
WORKFLOW="${WEBTUNNEL_WORKFLOW:-browser-session.yml}"

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
  echo "Usage: fetch-recording.sh <session> [出力ディレクトリ]" >&2
  exit 2
fi
SESSION=$1
OUT_DIR="${2:-./tmp/webtunnel-recording-${SESSION}}"

for required in gh jq; do
  command -v "$required" >/dev/null 2>&1 || { echo "${required} が必要" >&2; exit 1; }
done

runs_json=$(gh run list -R "$REPO" --workflow "$WORKFLOW" -L 30 --json databaseId,displayTitle,status)
run=$(echo "$runs_json" | jq -c --arg session "$SESSION" \
  '[.[] | select(.displayTitle | startswith("session=" + $session + " "))] | first')

if [ -z "$run" ] || [ "$run" = "null" ]; then
  echo "セッション ${SESSION} の run が ${REPO} の ${WORKFLOW} に見つからない" >&2
  exit 1
fi

run_id=$(echo "$run" | jq -r '.databaseId')
status=$(echo "$run" | jq -r '.status')
if [ "$status" != "completed" ]; then
  echo "run ${run_id} はまだ ${status}。録画はセッション終了時にアップロードされるため、webtunnel down ${SESSION} の後に再実行する" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
gh run download "$run_id" -R "$REPO" -n "recording-${SESSION}" -D "$OUT_DIR"
echo "downloaded: run ${run_id} → ${OUT_DIR}"
find "$OUT_DIR" -type f -name '*.mp4'
