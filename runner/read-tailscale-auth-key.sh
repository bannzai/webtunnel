#!/bin/bash
# actions/cache で受け取った auth key のファイル（mint-tailscale-auth-key.sh が書いたもの）を読み、
# sha256 が発行 job の output と一致することを確かめ、add-mask に登録してから step output `auth_key` に書く
# （tailscale/github-action の authkey input に渡す）。読んだファイルは消す。
# tailnet 参加の直前の step で実行し、env に置いて後続 step のプロセスへ引き継がない。
# env: AUTH_KEY_FILE / AUTH_KEY_SHA256 / GITHUB_OUTPUT
set -euo pipefail

: "${AUTH_KEY_FILE:?AUTH_KEY_FILE が未設定}"
: "${AUTH_KEY_SHA256:?AUTH_KEY_SHA256 が空（auth key 発行 job の output を受け取れていない）}"
[ -s "$AUTH_KEY_FILE" ] || {
  echo "auth key のファイルが無い（cache から復元できていない）" >&2
  exit 1
}

# cache のエントリは先に保存したものが残るため、caller repo の別の workflow が同じ key で先に置いた
# ファイルは sha256 の違いで止める
if [ "$(sha256sum "$AUTH_KEY_FILE" | cut -d ' ' -f 1)" != "$AUTH_KEY_SHA256" ]; then
  rm -f "$AUTH_KEY_FILE"
  echo "::error::cache から復元した auth key が発行 job の発行したものと一致しない" >&2
  exit 1
fi
auth_key="$(cat "$AUTH_KEY_FILE")"
rm -f "$AUTH_KEY_FILE"
echo "::add-mask::${auth_key}"
echo "auth_key=${auth_key}" >> "$GITHUB_OUTPUT"
