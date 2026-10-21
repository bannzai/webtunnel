#!/bin/bash
# mint-tailscale-auth-key.sh が暗号化した auth key を復号し、add-mask に登録してから
# step output `auth_key` に書く（tailscale/github-action の authkey input に渡す）。
# 復号は tailnet 参加の直前の step で行い、env に置いて後続 step のプロセスへ引き継がない。
# env: ENCRYPTED_AUTH_KEY / MINTED_RUN_ATTEMPT / TS_OIDC_CLIENT_ID / GITHUB_RUN_ATTEMPT / GITHUB_RUN_ID / GITHUB_OUTPUT
set -euo pipefail

: "${ENCRYPTED_AUTH_KEY:?ENCRYPTED_AUTH_KEY が空（auth key 発行 job の output を受け取れていない）}"
: "${TS_OIDC_CLIENT_ID:?TS_OIDC_CLIENT_ID が未設定}"

# auth key は single-use で有効期限も短いため、前の試行で発行したものは使えない
if [ "${MINTED_RUN_ATTEMPT:-}" != "${GITHUB_RUN_ATTEMPT:-}" ]; then
  echo "::error::auth key は試行 ${MINTED_RUN_ATTEMPT:-?} で発行したもので、現在の試行 ${GITHUB_RUN_ATTEMPT:-?} では使えない（使用済みか失効済み）。session job だけでなく「Re-run all jobs」（gh run rerun <run ID>、--failed なし）で再実行する" >&2
  exit 1
fi

# パスフレーズの組み立ては mint-tailscale-auth-key.sh と一致させる
auth_key="$(printf '%s' "$ENCRYPTED_AUTH_KEY" |
  WEBTUNNEL_AUTH_KEY_PASSPHRASE="${TS_OIDC_CLIENT_ID}:${GITHUB_RUN_ID}" \
    openssl enc -d -aes-256-cbc -pbkdf2 -a -A -pass env:WEBTUNNEL_AUTH_KEY_PASSPHRASE)"
[ -n "$auth_key" ] || {
  echo "auth key を復号できなかった" >&2
  exit 1
}
echo "::add-mask::${auth_key}"
echo "auth_key=${auth_key}" >> "$GITHUB_OUTPUT"
