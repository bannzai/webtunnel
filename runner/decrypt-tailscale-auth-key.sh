#!/bin/bash
# tailscale-auth-key job が session job の公開鍵で暗号化した auth key を、create-session-key-pair.sh が作った
# 秘密鍵で復号し、add-mask に登録してから step output `auth_key` に書く（tailscale/github-action の authkey input に渡す）。
# 復号の後に秘密鍵と暗号文は消す。tailnet 参加の直前の step で実行し、env に置いて後続 step のプロセスへ引き継がない。
# env: SESSION_PRIVATE_KEY_FILE / ENCRYPTED_AUTH_KEY_FILE / GITHUB_OUTPUT
set -euo pipefail

: "${SESSION_PRIVATE_KEY_FILE:?SESSION_PRIVATE_KEY_FILE が未設定}"
: "${ENCRYPTED_AUTH_KEY_FILE:?ENCRYPTED_AUTH_KEY_FILE が未設定}"
[ -s "$ENCRYPTED_AUTH_KEY_FILE" ] || {
  echo "::error::暗号化した auth key を受け取れなかった（tailscale-auth-key job の失敗か、待ちの打ち切り）。session job だけを再実行した場合は、「Re-run all jobs」（gh run rerun <run ID>、--failed なし）で再実行する" >&2
  exit 1
}

auth_key="$(openssl pkeyutl -decrypt -inkey "$SESSION_PRIVATE_KEY_FILE" \
  -pkeyopt rsa_padding_mode:oaep -pkeyopt rsa_oaep_md:sha256 -in "$ENCRYPTED_AUTH_KEY_FILE")"
rm -f "$SESSION_PRIVATE_KEY_FILE" "$ENCRYPTED_AUTH_KEY_FILE"
[ -n "$auth_key" ] || {
  echo "auth key を復号できなかった" >&2
  exit 1
}
echo "::add-mask::${auth_key}"
echo "auth_key=${auth_key}" >> "$GITHUB_OUTPUT"
