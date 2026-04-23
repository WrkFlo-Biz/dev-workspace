#!/usr/bin/env bash
# chrome-cdp-relay.sh — keep the Tailscale-facing Chrome CDP relay alive.
set -euo pipefail

TS_IP=$(/opt/homebrew/bin/tailscale ip -4 2>/dev/null | head -1 || true)
if [ -z "$TS_IP" ]; then
  echo "[chrome-cdp-relay] tailscale not up" >&2
  exit 1
fi

exec /opt/homebrew/bin/socat \
  "TCP-LISTEN:9222,bind=$TS_IP,fork,reuseaddr" \
  "TCP:127.0.0.1:9222"
