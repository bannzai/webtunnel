#!/bin/bash
# GitHub の OIDC トークンを Tailscale の workload identity federation で交換し、
# tag:ci の auth key（single-use・ephemeral・preauthorized）を発行して AUTH_KEY_FILE に書き、
# その sha256 を step output `auth_key_sha256` に書く。ファイルは workflow が actions/cache で session job へ渡す。
# caller のコードを一切実行しない job（id-token: write を持つ唯一の job）から呼ぶ。
# auth key を job output にしないのは、add-mask した値は job output から落とされ、落とされない値は
# 受け取る側の step の env 表示として public な run のログに出るため。暗号化して output にする方法は、
# 復号の鍵を session job（caller のコードが読める）に渡すことになり、鍵が一度漏れると以後の run の
# ログの暗号文をすべて復号できてしまうため採らない（参照: PROJECT.md「リポジトリ公開に耐える安全性」の 11）。
# env: TS_OIDC_CLIENT_ID / TS_OIDC_AUDIENCE / ACTIONS_ID_TOKEN_REQUEST_URL /
#      ACTIONS_ID_TOKEN_REQUEST_TOKEN / AUTH_KEY_FILE / GITHUB_OUTPUT
set -euo pipefail

: "${TS_OIDC_CLIENT_ID:?TS_OIDC_CLIENT_ID が未設定}"
: "${AUTH_KEY_FILE:?AUTH_KEY_FILE が未設定}"
: "${TS_OIDC_AUDIENCE:?TS_OIDC_AUDIENCE が未設定}"
: "${ACTIONS_ID_TOKEN_REQUEST_URL:?id-token: write が付与されていない（OIDC トークンを発行できない）}"
TS_API="${TS_API:-https://api.tailscale.com/api/v2}"
# auth key は使用時に失効する single-use のため、有効期限は「発行から tailnet 参加まで」を覆えばよい。
# session job の参加前の step 上限（dev サーバ 15 + Chromium 10 + セッション初期化 15 + 録画 5 + preview 5 分）
# に runner の割り当て待ちとツールチェーン準備の余裕を足した 90 分にする
AUTH_KEY_EXPIRY_SECONDS="${AUTH_KEY_EXPIRY_SECONDS:-5400}"

# エラー時に応答本文を出さない（-f）。応答にトークンが含まれうるため
id_token="$(curl -fsS -G -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
  --data-urlencode "audience=${TS_OIDC_AUDIENCE}" "$ACTIONS_ID_TOKEN_REQUEST_URL" | jq -r '.value')"
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

# 鍵は argv（/proc/*/cmdline）に出さず、builtin の printf でファイルに書く
(umask 077 && printf '%s' "$auth_key" > "$AUTH_KEY_FILE")
echo "auth_key_sha256=$(sha256sum "$AUTH_KEY_FILE" | cut -d ' ' -f 1)" >> "$GITHUB_OUTPUT"
echo "tag:ci の auth key を発行した（有効期限 ${AUTH_KEY_EXPIRY_SECONDS} 秒・single-use・ephemeral）"
