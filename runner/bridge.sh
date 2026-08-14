#!/bin/bash
# 引数で渡されたポート（省略時は 9222）の 127.0.0.1 を tailscale インターフェースへ中継する。
# すでに tailscale インターフェースで listen しているポートは何もしない（冪等）。
# simtunnel の runner/bridge.sh の Linux 版（socat の導入を brew から apt-get に変更）。
set -euo pipefail

# tailnet の実 IP は出力しない。public リポジトリでは run のログを誰でも読めるため
# （参照: PROJECT.md「リポジトリ公開に耐える安全性」）
TS_IP="$(tailscale ip -4 | head -1)"
[ -n "$TS_IP" ] || { echo "tailscale IP が取得できない" >&2; exit 1; }

reachable() {
  local port=$1
  nc -z -w 2 "$TS_IP" "$port" >/dev/null 2>&1
}

ensure_bridge() {
  local port=$1
  if reachable "$port"; then
    echo "port ${port}: すでに tailscale インターフェースで到達可能（bridge 不要）"
    return 0
  fi
  # 中継先の loopback は IPv4 / IPv6 のどちらで listen しているか分からないため実測で選ぶ
  local upstream="TCP:127.0.0.1:${port}"
  if ! nc -z -w 2 127.0.0.1 "$port" >/dev/null 2>&1 && nc -z -w 2 ::1 "$port" >/dev/null 2>&1; then
    upstream="TCP6:[::1]:${port}"
  fi
  command -v socat >/dev/null 2>&1 || {
    sudo apt-get update -qq
    sudo apt-get install -y -qq socat
  }
  nohup socat "TCP-LISTEN:${port},bind=${TS_IP},fork,reuseaddr" "$upstream" >/dev/null 2>&1 &
  sleep 1
  reachable "$port" || { echo "port ${port}: bridge の起動に失敗" >&2; exit 1; }
  echo "port ${port}: bridged tailscale インターフェース -> ${upstream}"
}

PORTS=("$@")
[ ${#PORTS[@]} -gt 0 ] || PORTS=(9222)
for port in "${PORTS[@]}"; do
  ensure_bridge "$port"
done
