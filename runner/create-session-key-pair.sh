#!/bin/bash
# session job が Tailscale の auth key を受け取るための、run ごとの RSA の鍵ペアを作る。
# 公開鍵は artifact で tailscale-auth-key job へ渡し、秘密鍵は decrypt-tailscale-auth-key.sh が使って消す。
# caller のコードを実行する step より前に呼ぶ（呼んだ後の caller のコードはこの run の秘密鍵を読めるが、
# 鍵は run ごとに作り捨てるため、以後の run の auth key には効かない。PROJECT.md「リポジトリ公開に耐える安全性」の 11）。
# 既存の鍵は作り直す（同じ step の再実行で前の公開鍵と秘密鍵が食い違わないように）。
# env: SESSION_PRIVATE_KEY_FILE / SESSION_PUBLIC_KEY_FILE
set -euo pipefail

: "${SESSION_PRIVATE_KEY_FILE:?SESSION_PRIVATE_KEY_FILE が未設定}"
: "${SESSION_PUBLIC_KEY_FILE:?SESSION_PUBLIC_KEY_FILE が未設定}"

mkdir -p "$(dirname "$SESSION_PRIVATE_KEY_FILE")" "$(dirname "$SESSION_PUBLIC_KEY_FILE")"
# 3072 bit は NIST SP 800-57 で 2030 年以降も使える 128 bit 相当の強度。OAEP (SHA-256) で暗号化できる
# 平文の上限（318 バイト）も auth key（100 バイト未満）を覆う
(umask 077 && openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$SESSION_PRIVATE_KEY_FILE" 2>/dev/null)
openssl pkey -in "$SESSION_PRIVATE_KEY_FILE" -pubout -out "$SESSION_PUBLIC_KEY_FILE"
