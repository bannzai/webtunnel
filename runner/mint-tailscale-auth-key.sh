#!/bin/bash
# GitHub の OIDC トークンを Tailscale の workload identity federation で交換し、
# tag:ci の auth key（single-use・ephemeral・preauthorized）を発行し、session job の run ごとの公開鍵
# （create-session-key-pair.sh が作り artifact で届いたもの）で暗号化して ENCRYPTED_AUTH_KEY_FILE に書く。
# 暗号文は workflow が artifact で session job へ返す。公開される前提の経路で、復号できるのはこの run の
# session job だけ（参照: PROJECT.md「リポジトリ公開に耐える安全性」の 11）。
# caller のコードを一切実行しない job（id-token: write を持つ唯一の job）から呼ぶ。
# env: TS_OIDC_CLIENT_ID / TS_OIDC_AUDIENCE / ACTIONS_ID_TOKEN_REQUEST_URL /
#      ACTIONS_ID_TOKEN_REQUEST_TOKEN / SESSION_PUBLIC_KEY_FILE / ENCRYPTED_AUTH_KEY_FILE
set -euo pipefail

: "${TS_OIDC_CLIENT_ID:?TS_OIDC_CLIENT_ID が未設定}"
: "${ENCRYPTED_AUTH_KEY_FILE:?ENCRYPTED_AUTH_KEY_FILE が未設定}"
[ -s "${SESSION_PUBLIC_KEY_FILE:-}" ] || {
  echo "::error::session job の公開鍵を受け取れなかった（session job が鍵を作る前に失敗したか、待ちの打ち切り）" >&2
  exit 1
}
: "${TS_OIDC_AUDIENCE:?TS_OIDC_AUDIENCE が未設定}"
: "${ACTIONS_ID_TOKEN_REQUEST_URL:?id-token: write が付与されていない（OIDC トークンを発行できない）}"
TS_API="${TS_API:-https://api.tailscale.com/api/v2}"
# auth key は使用時に失効する single-use のため、有効期限は「発行から tailnet 参加まで」を覆えばよい。
# 発行は session job の公開鍵が届いた直後（session job の開始直後）で、そこからの session job の参加前の step 上限（dev サーバ 15 + Chromium 10 + セッション初期化 15 + 録画 5 + preview 5 分）
# に runner の割り当て待ちとツールチェーン準備の余裕を足した 90 分にする
AUTH_KEY_EXPIRY_SECONDS="${AUTH_KEY_EXPIRY_SECONDS:-5400}"

# エラー時に応答本文を出さない（-f）。応答にトークンが含まれうるため
id_token="$(curl -fsS -G -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
  --data-urlencode "audience=${TS_OIDC_AUDIENCE}" "$ACTIONS_ID_TOKEN_REQUEST_URL" | jq -r '.value')"
[ -n "$id_token" ] && [ "$id_token" != "null" ] || {
  echo "GitHub の OIDC トークンを取得できなかった" >&2
  exit 1
}
echo "::add-mask::${id_token}"

# 失敗の文言は tailscale up（--client-id / --id-token）と同じ形にする。credential の Subject 違い等の
# 403 の切り分け手順（PROJECT.md「新しいプロジェクトに webtunnel を導入する」）がこの文言で引けるため
exchange_response="$(mktemp)"
exchange_status="$(curl -sS -o "$exchange_response" -w '%{http_code}' -X POST "${TS_API}/oauth/token-exchange" \
  --data-urlencode "client_id=${TS_OIDC_CLIENT_ID}" \
  --data-urlencode "jwt=${id_token}")"
[ "$exchange_status" = "200" ] || {
  echo "failed to exchange JWT for access token: token exchange failed with status ${exchange_status}" >&2
  exit 1
}
access_token="$(jq -r '.access_token' "$exchange_response")"
rm -f "$exchange_response"
[ -n "$access_token" ] && [ "$access_token" != "null" ] || {
  echo "Tailscale の token exchange が access token を返さなかった" >&2
  exit 1
}
echo "::add-mask::${access_token}"

# 内容は tailscale/github-action の OIDC 経路（tailscale up --client-id=...?preauthorized=true&ephemeral=true）が
# 発行する auth key と同じにする。有効期限だけを明示して短くする
auth_key="$(jq -n --argjson expiry "$AUTH_KEY_EXPIRY_SECONDS" '{
    capabilities: {devices: {create: {reusable: false, ephemeral: true, preauthorized: true, tags: ["tag:ci"]}}},
    expirySeconds: $expiry
  }' | curl -fsS -X POST "${TS_API}/tailnet/-/keys" \
    -H "Authorization: Bearer ${access_token}" \
    -H "Content-Type: application/json" \
    --data-binary @- | jq -r '.key')"
[ -n "$auth_key" ] && [ "$auth_key" != "null" ] || {
  echo "Tailscale が auth key を返さなかった" >&2
  exit 1
}
echo "::add-mask::${auth_key}"

# 鍵は argv（/proc/*/cmdline）に出さず、builtin の printf で stdin に渡す
mkdir -p "$(dirname "$ENCRYPTED_AUTH_KEY_FILE")"
printf '%s' "$auth_key" | openssl pkeyutl -encrypt -pubin -inkey "$SESSION_PUBLIC_KEY_FILE" \
  -pkeyopt rsa_padding_mode:oaep -pkeyopt rsa_oaep_md:sha256 -out "$ENCRYPTED_AUTH_KEY_FILE"
echo "tag:ci の auth key を発行した（有効期限 ${AUTH_KEY_EXPIRY_SECONDS} 秒・single-use・ephemeral）"
